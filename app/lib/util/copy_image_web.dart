// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'media_cache.dart';

String _mimeFor(String? filename, String url) {
  final name = (filename != null && filename.isNotEmpty)
      ? filename
      : url.split('?').first;
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  return 'image/png';
}

/// Blobs already fetched for copy, keyed by URL. Images are warmed as soon as
/// they render in a chat bubble, so copying one that was shown on screen is
/// instant — no network wait.
final Map<String, web.Blob> _blobCache = {};
const _maxCachedBlobs = 24;

/// URLs with a fetch in flight — prevents duplicate parallel downloads when
/// display warming and a menu-open prefetch both ask for the same image.
final Set<String> _inflight = {};

web.Blob _blobFromBytes(Uint8List bytes, String url) =>
    web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: _mimeFor(null, url)));

void _cacheBlob(String url, web.Blob blob, {bool alreadyPersisted = false}) {
  if (_blobCache.length >= _maxCachedBlobs && !_blobCache.containsKey(url)) {
    _blobCache.remove(_blobCache.keys.first);
  }
  _blobCache[url] = blob;
  if (alreadyPersisted) return;
  // Write through to the persistent IndexedDB cache so the same single fetch
  // feeds "Copy image", instant lightbox opens, and reloads.
  unawaited(_persistBlob(url, blob));
}

Future<void> _persistBlob(String url, web.Blob blob) async {
  print('[media-warm] persist start $url size=${blob.size}');
  try {
    final bytes = await _readBlobBytes(blob);
    print('[media-warm] readBytes ${bytes == null ? "NULL" : bytes.length}');
    if (bytes != null && bytes.isNotEmpty) {
      await mediaCacheWarmBytes(url, bytes);
      print('[media-warm] warm done $url');
    }
  } catch (e) {
    reportMediaCacheError('persistBlob', '$url: $e');
  }
}

Future<Uint8List?> _readBlobBytes(web.Blob blob) async {
  try {
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } catch (_) {
    return null;
  }
}

/// Fetches [url] as a Blob. The browser serves already-displayed images from
/// its HTTP cache, so this is fast for anything rendered in the chat.
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

/// Warms [_blobCache] for [url] ahead of a copy (menu open or image shown).
/// Serves already-persisted cache bytes when available so warming never causes
/// a server download for media that is already local.
Future<void> prefetchImageForCopy(String url) async {
  if (_blobCache.containsKey(url) || _inflight.contains(url)) return;
  _inflight.add(url);
  try {
    web.Blob? blob;
    var alreadyPersisted = false;
    final bytes = await mediaCacheGet(url);
    if (bytes != null && bytes.isNotEmpty) {
      blob = _blobFromBytes(bytes, url);
      alreadyPersisted = true;
    } else {
      blob = await _fetchBlob(url);
    }
    if (blob != null) {
      _cacheBlob(url, blob, alreadyPersisted: alreadyPersisted);
    }
  } catch (_) {
    // Fall through — the copy path will retry the fetch itself.
  } finally {
    _inflight.remove(url);
  }
}

/// Fetches [url] as a Blob and writes it to the system clipboard through the
/// Async Clipboard API — the browser "Copy image" equivalent. Must be called
/// from a user gesture (right-click → menu tap) so Chromium keeps the
/// transient activation alive for the fetch + write.
Future<bool> copyImageToClipboard(String url, {String? filename}) async {
  try {
    var data = _blobCache[url];
    if (data == null) {
      // Already cached from a previous session — no network needed.
      final bytes = await mediaCacheGet(url);
      if (bytes != null && bytes.isNotEmpty) {
        data = _blobFromBytes(bytes, url);
        _cacheBlob(url, data, alreadyPersisted: true);
      }
    }
    if (data == null) {
      data = await _fetchBlob(url);
      if (data == null) return false;
      _cacheBlob(url, data);
    }

    final clipboard = web.window.navigator.clipboard;

    final type = data.type.isNotEmpty ? data.type : _mimeFor(filename, url);
    final items = JSObject()..setProperty(type.toJS, data);
    final item = web.ClipboardItem(items);
    await clipboard.write([item].toJS).toDart;
    return true;
  } catch (_) {
    return false;
  }
}
