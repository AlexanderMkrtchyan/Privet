import 'reveal_file_stub.dart'
    if (dart.library.io) 'reveal_file_io.dart' as impl;

/// Opens the file manager with [path] selected. No-op on web.
Future<bool> revealInFileManager(String path) => impl.revealInFileManager(path);
