import 'media_download_stub.dart'
    if (dart.library.html) 'media_download_web.dart' as impl;

/// Triggers a browser/native download for [url] with optional [filename].
Future<void> downloadMedia(String url, {String? filename}) =>
    impl.downloadMedia(url, filename: filename);
