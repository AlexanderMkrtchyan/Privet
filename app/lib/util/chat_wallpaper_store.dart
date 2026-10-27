import 'dart:typed_data';

import 'chat_wallpaper_store_stub.dart'
    if (dart.library.html) 'chat_wallpaper_store_web.dart'
    if (dart.library.io) 'chat_wallpaper_store_io.dart' as impl;

/// Persists the user's uploaded chat background across restarts.
Future<void> saveCustomChatWallpaper(Uint8List bytes) =>
    impl.saveCustomChatWallpaper(bytes);

Future<Uint8List?> loadCustomChatWallpaper() => impl.loadCustomChatWallpaper();
