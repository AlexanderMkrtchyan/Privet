import 'media_cache.dart';

/// Downloads [url] straight to the OS Downloads folder — no external browser
/// involved. Cached bytes are reused when available, so re-saving a file
/// already shown in chat is instant instead of a fresh server download.
/// Returns the saved path, or null when the download failed.
Future<String?> downloadMedia(String url, {String? filename}) =>
    downloadMediaFromCache(url, filename: filename);
