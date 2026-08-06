import 'copy_image_stub.dart'
    if (dart.library.html) 'copy_image_web.dart'
    if (dart.library.io) 'copy_image_io.dart' as impl;

/// Copies the image at [url] to the system clipboard as real image data
/// (equivalent to a browser "Copy image").
///
/// Returns true on success. Returns false when the platform has no image
/// clipboard (Flutter native builds) or the write failed — the caller should
/// fall back to Download in that case.
Future<bool> copyImageToClipboard(String url, {String? filename}) =>
    impl.copyImageToClipboard(url, filename: filename);

/// Warms the platform copy cache for [url] ahead of a possible
/// [copyImageToClipboard] call. Call this when a context menu opens so the
/// image bytes are already local by the time the user taps "Copy image".
Future<void> prefetchImageForCopy(String url) => impl.prefetchImageForCopy(url);
