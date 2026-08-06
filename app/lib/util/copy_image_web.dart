// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:js_util' as js_util;

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
final Map<String, html.Blob> _blobCache = {};
const _maxCachedBlobs = 24;

/// URLs with a fetch in flight — prevents duplicate parallel downloads when
/// display warming and a menu-open prefetch both ask for the same image.
final Set<String> _inflight = {};

void _cacheBlob(String url, html.Blob blob) {
  if (_blobCache.length >= _maxCachedBlobs && !_blobCache.containsKey(url)) {
    _blobCache.remove(_blobCache.keys.first);
  }
  _blobCache[url] = blob;
}

/// Fetches [url] as a Blob. The browser serves already-displayed images from
/// its HTTP cache, so this is fast for anything rendered in the chat.
Future<html.Blob?> _fetchBlob(String url) async {
  final response = await html.HttpRequest.request(
    url,
    method: 'GET',
    responseType: 'blob',
  );
  final data = response.response;
  return data is html.Blob && data.size > 0 ? data : null;
}

/// Warms [_blobCache] for [url] ahead of a copy (menu open or image shown).
Future<void> prefetchImageForCopy(String url) async {
  if (_blobCache.containsKey(url) || _inflight.contains(url)) return;
  _inflight.add(url);
  try {
    final blob = await _fetchBlob(url);
    if (blob != null) _cacheBlob(url, blob);
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
      data = await _fetchBlob(url);
      if (data == null) return false;
      _cacheBlob(url, data);
    }

    final clipboard = js_util.getProperty(html.window.navigator, 'clipboard');
    if (clipboard == null) return false;
    final ctor = js_util.getProperty(html.window, 'ClipboardItem');
    if (ctor == null) return false;

    final type = data.type.isNotEmpty ? data.type : _mimeFor(filename, url);
    final item = js_util.callConstructor(
      ctor,
      [js_util.jsify(<String, dynamic>{type: data})],
    );
    await js_util.promiseToFuture(
      js_util.callMethod(clipboard, 'write', [js_util.jsify([item])]),
    );
    return true;
  } catch (_) {
    return false;
  }
}
