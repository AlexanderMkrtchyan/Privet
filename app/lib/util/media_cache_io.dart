import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Max media entries kept on disk, oldest evicted first (LRU).
const int kMediaCacheMaxEntries = 20;

/// Single files bigger than this are never cached (huge videos etc.).
const int _maxEntryBytes = 20 * 1024 * 1024;

/// Hard total disk budget for the cache — LRU also prunes by bytes.
const int _maxTotalBytes = 256 * 1024 * 1024;

/// In-memory instant window. Reading a file off disk is fast, but keeping the
/// most recent bytes in RAM makes the click-to-open path truly synchronous.
const int _maxMemBytes = 64 * 1024 * 1024;

/// How many most-recent entries to preload into memory at startup so the very
/// first open after launch is instant too. Covers the whole cache (20 files).
const int _preloadAtInit = kMediaCacheMaxEntries;

Directory? _cacheDir;
bool _initialized = false;
Future<void> _init = Future.value();

/// LRU list, oldest first. Mirrored to disk in index.json.
final List<_CacheEntry> _entries = [];
final Map<String, Uint8List> _mem = {};
int _memBytes = 0;

/// URLs with a fetch in flight — prevents duplicate parallel downloads when
/// several surfaces warm the same media at once.
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

Future<void> initMediaCache() {
  if (_initialized) return _init;
  _initialized = true;
  _init = _doInit();
  return _init;
}

Future<void> _doInit() async {
  try {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'media_cache'));
    await dir.create(recursive: true);
    _cacheDir = dir;
    await _synchronized(_loadIndex);
    // Preload the most recent few entries so the first open after launch is
    // instant without re-downloading.
    for (final entry in _entries.reversed.take(_preloadAtInit)) {
      if (_memBytes >= _maxMemBytes) break;
      unawaited(_loadEntryBytes(entry));
    }
  } catch (_) {
    // Cache unavailable (e.g. sandboxed test env) — the app works without it.
  }
}

Future<void> _loadIndex() async {
  final dir = _cacheDir;
  if (dir == null) return;
  _entries.clear();
  final file = File(p.join(dir.path, 'index.json'));
  try {
    if (!await file.exists()) return;
    final text = await file.readAsString();
    final decoded = jsonDecode(text);
    if (decoded is! List) return;
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final entry = _CacheEntry.fromJson(raw.cast<String, dynamic>());
      if (entry.file.isEmpty) continue;
      _entries.add(entry);
    }
  } catch (_) {}
}

Future<void> _saveIndex() async {
  final dir = _cacheDir;
  if (dir == null) return;
  try {
    final file = File(p.join(dir.path, 'index.json'));
    await file.writeAsString(
      jsonEncode([for (final e in _entries) e.toJson()]),
    );
  } catch (_) {}
}

/// Completes when the cache index is loaded. When [initMediaCache] has not run
/// yet (e.g. a widget test that never booted main.dart, or an app frame racing
/// startup), there is nothing on disk to read, so resolve immediately instead
/// of blocking on a platform-backed init.
Future<void> _ensureInit() {
  if (_initialized) return _init;
  return Future.value();
}

Uint8List? mediaCacheLookupSync(String url) => _mem[url];

Future<Uint8List?> mediaCacheGet(String url) async {
  await _ensureInit();
  final mem = _mem[url];
  if (mem != null) return mem;
  final entry = _find(url);
  if (entry == null) return null;
  final bytes = await _readEntryBytes(entry);
  if (bytes == null) return null;
  _remember(url, bytes);
  // LRU touch is bookkeeping only — don't block the read on the index write.
  unawaited(_synchronized(() => _touch(entry)));
  return bytes;
}

Future<Uint8List?> mediaCacheGetOrFetch(String url) async {
  await _ensureInit();
  final cached = await mediaCacheGet(url);
  if (cached != null) return cached;
  if (_inflight.contains(url)) return null;
  _inflight.add(url);
  try {
    final bytes = await _fetch(url);
    if (bytes == null) return null;
    await _store(url, bytes);
    return _mem[url] ?? bytes;
  } catch (_) {
    return null;
  } finally {
    _inflight.remove(url);
  }
}

Future<void> mediaCacheWarmBytes(String url, Uint8List bytes) async {
  await _ensureInit();
  if (bytes.isEmpty) return;
  await _store(url, bytes);
}

/// Native platforms have no console diagnostic hook — no-op.
void reportMediaCacheError(String where, String detail) {}

Future<String?> downloadMediaFromCache(String url, {String? filename}) async {
  final bytes = await mediaCacheGetOrFetch(url);
  if (bytes == null) return null;
  try {
    final dir = await getDownloadsDirectory() ??
        await getApplicationSupportDirectory();
    final name = _safeDownloadName(filename ?? _nameFromUrl(url));
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _fetch(String url) async {
  final response = await http
      .get(Uri.parse(url))
      .timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) return null;
  final bytes = response.bodyBytes;
  return bytes.isEmpty ? null : bytes;
}

Future<void> _store(String url, Uint8List bytes) async {
  if (bytes.length > _maxEntryBytes) return;
  await _synchronized(() async {
    final dir = _cacheDir;
    if (dir == null) return;
    final name = _fileNameFor(url);
    final old = _find(url);
    try {
      await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);
    } catch (_) {
      return;
    }
    if (old != null) _entries.remove(old);
    _entries.add(_CacheEntry(url, name, bytes.length));
    _remember(url, bytes);
    await _prune();
    await _saveIndex();
    if (old != null && old.file != name) {
      try {
        await File(p.join(dir.path, old.file)).delete();
      } catch (_) {}
    }
  });
}

Future<void> _touch(_CacheEntry entry) async {
  _entries.remove(entry);
  _entries.add(entry);
  await _saveIndex();
}

Future<void> _prune() async {
  final dir = _cacheDir;
  if (dir == null) return;
  var total = _entries.fold<int>(0, (sum, e) => sum + e.size);
  while ((_entries.length > kMediaCacheMaxEntries || total > _maxTotalBytes) &&
      _entries.isNotEmpty) {
    // Skip entries pinned by the warm pass — evicting one the pass is about
    // to download (or already holds) makes the pass re-download it, so the
    // cache churns on every boot. Fall back to the oldest entry when the whole
    // cache is pinned (queue wider than the cache).
    var i = 0;
    while (i < _entries.length && _pinned.contains(_entries[i].url)) {
      i++;
    }
    if (i >= _entries.length) i = 0;
    final victim = _entries.removeAt(i);
    total -= victim.size;
    _dropMem(victim.url);
    try {
      await File(p.join(dir.path, victim.file)).delete();
    } catch (_) {}
  }
}

_CacheEntry? _find(String url) {
  for (final entry in _entries) {
    if (entry.url == url) return entry;
  }
  return null;
}

Future<Uint8List?> _readEntryBytes(_CacheEntry entry) async {
  final dir = _cacheDir;
  if (dir == null) return null;
  try {
    final file = File(p.join(dir.path, entry.file));
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}

Future<void> _loadEntryBytes(_CacheEntry entry) async {
  final dir = _cacheDir;
  if (dir == null) return;
  try {
    final file = File(p.join(dir.path, entry.file));
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return;
    _remember(entry.url, bytes);
  } catch (_) {}
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

String _fileNameFor(String url) {
  final segments = url
      .split('?')
      .first
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  var base = segments.isEmpty ? 'media' : segments.last;
  if (base.length > 64) base = base.substring(base.length - 64);
  final hash = url.hashCode.abs().toRadixString(16);
  return '${base}_$hash.bin';
}

String _safeDownloadName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final base = cleaned.isEmpty ? 'download' : cleaned;
  return base.length > 120 ? base.substring(base.length - 120) : base;
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

class _CacheEntry {
  _CacheEntry(this.url, this.file, this.size);

  final String url;
  final String file;
  final int size;

  Map<String, dynamic> toJson() => {'url': url, 'file': file, 'size': size};

  static _CacheEntry fromJson(Map<String, dynamic> json) => _CacheEntry(
        json['url'] as String,
        json['file'] as String,
        (json['size'] as num).toInt(),
      );
}
