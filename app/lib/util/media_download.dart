import 'media_download_stub.dart'
    if (dart.library.html) 'media_download_web.dart'
    if (dart.library.io) 'media_download_io.dart' as impl;

/// Downloads [url] with optional [filename]. On native platforms the file is
/// saved straight to the OS Downloads folder and the saved path is returned;
/// on web the browser handles the download itself and null is returned.
Future<String?> downloadMedia(String url, {String? filename}) =>
    impl.downloadMedia(url, filename: filename);
