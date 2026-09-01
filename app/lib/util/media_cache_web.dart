// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Max media entries kept in IndexedDB, oldest evicted first (LRU).
const int kMediaCacheMaxEntries = 20;

const int _maxEntryBytes = 20 * 1024 * 1024;
const int _maxTotalBytes = 256 * 1024 * 1024;
const int _maxMemBytes = 64 * 1024 * 1024;

const _dbName = 'privet_media_cache';
const _dbVersion = 1;
const _storeName = 'blobs';
const _orderKey = 'privet_media_cache_order';
const _sizesKey = 'privet_media_cache_sizes';

Future<web.IDBDatabase>? _db;
final Map<String, Uint8List> _mem = {};
int _memBytes = 0;
final Set<String> _inflight = {};

/// URLs currently pinned by the warm pass — the evictor skips these so a
/// pre-warm download never evicts another still-current entry (which the same
/// pass would then re-download, churning the cache on every boot).
final Set<String> _pinned = {};

void mediaCachePin(Iterable<String> urls) {
  _pinned
    ..clear()
    ..addAll(urls);
}

void mediaCacheUnpin() => _pinned.clear();

/// Serializes index mutations (store / touch / prune) across awaits.
Future<void> _lock = Future.value();
Future<T> _synchronized<T>(Future<T> Function() fn) {
  final result = _lock.then((_) => fn());
  _lock = result.then((_) {}, onError: (_) {});
  return result;
}

Future<void> initMediaCache() async {
  try {
    await _database();
  } catch (e) {
    _diag('init-open-failed', '$e');
    return;
  }
  // Fire-and-forget self-probe: stores + reads back a tiny blob so a silent
  // IndexedDB failure is observable (surfaced on window.__privetMediaCacheDiag)
  // instead of quietly disabling the cache.
  unawaited(_runSelfProbe());
}

/// Boot-time IndexedDB round-trip probe. Exposes its result on
/// `window.__privetMediaCacheDiag` (status ok / store-failed / read-back-null /
/// delete-failed) so web cache health is verifiable from the console.
Future<void> _runSelfProbe() async {
  const probeKey = '__privet_media_cache_probe__';
  try {
    final probe = _blobFromBytes(probeKey, Uint8List.fromList([1, 2, 3]));
    await _putBlob(probeKey, probe);
    final back = await _getBlob(probeKey);
    if (back == null) {
      _diag('probe-read-back-null', 'put ok but get returned null');
      return;
    }
    await _deleteBlob(probeKey);
    _diag('probe-ok');
  } catch (e) {
    _diag('probe-failed', '$e');
  }
}

/// Diagnostic hook for cache internals — mirrors the last event onto
/// `window.__privetMediaCacheDiag` so failures are inspectable from the
/// browser console / CDP instead of being swallowed.
void reportMediaCacheError(String where, String detail) =>
    _diag('error-$where', detail);

void _diag(String event, [String? detail]) {
  print('[media-store] diag $event${detail == null ? '' : ' $detail'}');
  try {
    final payload = jsonEncode({
      'event': event,
      if (detail != null) 'detail': detail,
      'at': DateTime.now().toIso8601String(),
    });
    globalContext.setProperty('__privetMediaCacheDiag'.toJS, payload.toJS);
  } catch (_) {}
}

Future<web.IDBDatabase> _database() {
  final existing = _db;
  if (existing != null) return existing;
  final future = _openDb();
  _db = future;
  // A rejected open must not poison the cache for the whole page session
  // (every later store/get would silently no-op through this cached future).
  // Clear it so the next access retries from scratch — storage can become
  // available later (unlock, quota relief, transient private-mode quirk).
  unawaited(future.then<void>((db) {}, onError: (Object error, StackTrace st) {
    if (identical(_db, future)) _db = null;
    _diag('db-open-failed', '$error');
  }));
  return future;
}

Future<web.IDBDatabase> _openDb() {
  final completer = Completer<web.IDBDatabase>();
  try {
    final factory = web.window.indexedDB;
    final request = factory.open(_dbName, _dbVersion);
    request.onupgradeneeded = (web.Event event) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }.toJS;
    request.onsuccess = (web.Event event) {
      if (!completer.isCompleted) {
        completer.complete(request.result as web.IDBDatabase);
      }
    }.toJS;
    request.onerror = (web.Event event) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('IndexedDB open failed'));
      }
    }.toJS;
  } catch (e) {
    completer.completeError(e);
  }
  return completer.future;
}

Future<JSAny?> _requestDone(web.IDBRequest request) {
  final completer = Completer<JSAny?>();
  request.onsuccess = (web.Event event) {
    if (!completer.isCompleted) completer.complete(request.result);
  }.toJS;
  request.onerror = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('IndexedDB request failed'));
    }
  }.toJS;
  return completer.future;
}

Future<void> _txDone(web.IDBTransaction tx) {
  final completer = Completer<void>();
  tx.oncomplete = (web.Event event) {
    if (!completer.isCompleted) completer.complete();
  }.toJS;
  tx.onerror = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('IndexedDB transaction failed'));
    }
  }.toJS;
  tx.onabort = (web.Event event) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('IndexedDB transaction aborted'));
    }
  }.toJS;
  return completer.future;
}

Future<void> _putBlob(String url, web.Blob blob) async {
  final db = await _database();
  final tx = db.transaction(_storeName.toJS, 'readwrite');
  await _requestDone(tx.objectStore(_storeName).put(blob, url.toJS));
  await _txDone(tx);
}

Future<web.Blob?> _getBlob(String url) async {
  final db = await _database();
  final tx = db.transaction(_storeName.toJS, 'readonly');
  final result = await _requestDone(tx.objectStore(_storeName).get(url.toJS));
  if (result == null) return null;
  return result as web.Blob?;
}

Future<void> _deleteBlob(String url) async {
  final db = await _database();
  final tx = db.transaction(_storeName.toJS, 'readwrite');
  await _requestDone(tx.objectStore(_storeName).delete(url.toJS));
  await _txDone(tx);
}

String? _lsGet(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void _lsSet(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } catch (_) {}
}

List<String> _readOrder() {
  try {
    final raw = _lsGet(_orderKey);
    if (raw == null || raw.isEmpty) return <String>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <String>[];
    return decoded.whereType<String>().toList();
  } catch (_) {
    return <String>[];
  }
}

Map<String, int> _readSizes() {
  try {
    final raw = _lsGet(_sizesKey);
    if (raw == null || raw.isEmpty) return <String, int>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return <String, int>{};
    final out = <String, int>{};
    decoded.forEach((key, value) {
      if (value is num) out['$key'] = value.toInt();
    });
    return out;
  } catch (_) {
    return <String, int>{};
  }
}

void _writeIndex(List<String> order, Map<String, int> sizes) {
  _lsSet(_orderKey, jsonEncode(order));
  _lsSet(_sizesKey, jsonEncode(sizes));
}

bool _known(String url) => _readOrder().contains(url);

Uint8List? mediaCacheLookupSync(String url) => _mem[url];

Future<Uint8List?> mediaCacheGet(String url) async {
  final mem = _mem[url];
  if (mem != null) return mem;
  if (!_known(url)) return null;
  try {
    final blob = await _getBlob(url);
    if (blob == null || blob.size <= 0) return null;
    final bytes = await _blobBytes(blob);
    if (bytes == null || bytes.isEmpty) return null;
    _remember(url, bytes);
    // LRU touch is bookkeeping only — don't block the read on the index write.
    unawaited(_touch(url));
    return bytes;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> mediaCacheGetOrFetch(String url) async {
  final cached = await mediaCacheGet(url);
  if (cached != null) return cached;
  if (_inflight.contains(url)) return null;
  _inflight.add(url);
  try {
    final blob = await _fetchBlob(url);
    if (blob == null || blob.size <= 0) return null;
    final bytes = await _blobBytes(blob);
    if (bytes == null || bytes.isEmpty) return null;
    await _store(url, blob);
    return bytes;
  } catch (_) {
    return null;
  } finally {
    _inflight.remove(url);
  }
}

Future<void> mediaCacheWarmBytes(String url, Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > _maxEntryBytes) return;
  await _store(url, _blobFromBytes(url, bytes));
}

Future<String?> downloadMediaFromCache(String url, {String? filename}) async {
  final bytes = await mediaCacheGetOrFetch(url);
  if (bytes == null) return null;
  final name = (filename != null && filename.isNotEmpty)
      ? filename
      : _nameFromUrl(url);
  try {
    final blob = _blobFromBytes(url, bytes);
    final objectUrl = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
    anchor.href = objectUrl;
    anchor.download = name;
    anchor.style.display = 'none';
    web.document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();
    web.URL.revokeObjectURL(objectUrl);
  } catch (_) {}
  return null;
}

Future<void> _touch(String url) => _synchronized(() async {
      final order = _readOrder();
      if (order.remove(url)) {
        order.add(url);
        _writeIndex(order, _readSizes());
      }
    });

Future<void> _store(String url, web.Blob blob) => _synchronized(() async {
      try {
        await _putBlob(url, blob);
      } catch (e) {
        _diag('store-failed', '$url: $e');
        return;
      }
      final order = _readOrder();
      order.remove(url);
      order.add(url);
      final sizes = _readSizes();
      sizes[url] = blob.size;
      final bytes = await _blobBytes(blob);
      if (bytes != null) _remember(url, bytes);

      var total = sizes.values.fold<int>(0, (sum, size) => sum + size);
      while ((order.length > kMediaCacheMaxEntries || total > _maxTotalBytes) &&
          order.isNotEmpty) {
        // Skip entries pinned by the warm pass — evicting one the pass is
        // about to download (or already holds) makes the pass re-download it,
        // so the cache churns on every boot. Fall back to the oldest entry
        // when the whole cache is pinned (queue wider than the cache).
        var i = 0;
        while (i < order.length && _pinned.contains(order[i])) {
          i++;
        }
        if (i >= order.length) i = 0;
        final victim = order.removeAt(i);
        final victimSize = sizes.remove(victim);
        if (victimSize != null) total -= victimSize;
        _dropMem(victim);
        try {
          await _deleteBlob(victim);
        } catch (_) {}
      }
      _writeIndex(order, sizes);
    });

Future<web.Blob?> _fetchBlob(String url) async {
  try {
    final response = await web.window.fetch(url.toJS).toDart;
    if (!response.ok) return null;
    final blob = await response.blob().toDart;
    return blob.size > 0 ? blob : null;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _blobBytes(web.Blob blob) async {
  try {
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } catch (_) {
    return null;
  }
}

web.Blob _blobFromBytes(String url, Uint8List bytes) =>
    web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: _mimeFor(url)));

String _mimeFor(String url) {
  final lower = url.split('?').first.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  return 'application/octet-stream';
}

void _remember(String url, Uint8List bytes) {
  final prev = _mem[url];
  if (prev != null) _memBytes -= prev.length;
  _mem[url] = bytes;
  _memBytes += bytes.length;
  _trimMem();
}

void _dropMem(String url) {
  final bytes = _mem.remove(url);
  if (bytes != null) _memBytes -= bytes.length;
}

void _trimMem() {
  while (_memBytes > _maxMemBytes && _mem.isNotEmpty) {
    _dropMem(_mem.keys.first);
  }
}

String _nameFromUrl(String url) {
  final segments = url
      .split('?')
      .first
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  return segments.isEmpty ? 'download' : segments.last;
}
