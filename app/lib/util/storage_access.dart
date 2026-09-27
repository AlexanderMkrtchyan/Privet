import 'storage_access_stub.dart'
    if (dart.library.io) 'storage_access_io.dart' as impl;

/// Asks Android for gallery / Downloads read access before the file picker
/// opens Videos or Downloads. No-op on other platforms.
Future<void> requestReadMediaAccess() => impl.requestReadMediaAccess();
