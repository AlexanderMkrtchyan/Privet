import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'app_image_clipboard.dart';
import 'remote_input.dart';

/// Raw image bytes already fetched for copy, keyed by URL. Images are warmed
/// as soon as they are rendered in a chat bubble, so copying one that was shown
/// on screen is instant — no network wait.
final Map<String, Uint8List> _bytesCache = {};
const _maxCachedBytes = 24;

/// URLs with a fetch in flight — prevents duplicate parallel downloads when
/// display warming and a menu-open prefetch both ask for the same image.
final Set<String> _inflight = {};

void _cacheBytes(String url, Uint8List bytes) {
  if (_bytesCache.length >= _maxCachedBytes && !_bytesCache.containsKey(url)) {
    _bytesCache.remove(_bytesCache.keys.first);
  }
  _bytesCache[url] = bytes;
}

Future<Uint8List?> _fetchBytes(String url) async {
  final response = await http
      .get(Uri.parse(url))
      .timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) return null;
  final bytes = response.bodyBytes;
  return bytes.isEmpty ? null : bytes;
}

/// Warms [_bytesCache] for [url] ahead of a copy (menu open or image shown).
Future<void> prefetchImageForCopy(String url) async {
  if (_bytesCache.containsKey(url) || _inflight.contains(url)) return;
  _inflight.add(url);
  try {
    final bytes = await _fetchBytes(url);
    if (bytes != null) _cacheBytes(url, bytes);
  } catch (_) {
    // Fall through — the copy path will retry the fetch itself.
  } finally {
    _inflight.remove(url);
  }
}

/// Fetches the image at [url] and writes it to the OS clipboard through the
/// native GTK plugin (`setClipboardImage`). The plugin decodes whatever image
/// format the server returned (PNG/JPEG/GIF/WebP) and advertises it as an
/// image so other apps can paste it.
Future<bool> copyImageToClipboard(String url, {String? filename}) async {
  try {
    var bytes = _bytesCache[url];
    if (bytes == null) {
      bytes = await _fetchBytes(url);
      if (bytes == null) return false;
      _cacheBytes(url, bytes);
    }
    rememberCopiedImage(bytes);
    return await RemoteInput.setClipboardImage(bytes);
  } catch (_) {
    return false;
  }
}
