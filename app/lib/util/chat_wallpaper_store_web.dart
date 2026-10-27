import 'dart:typed_data';

import 'media_cache.dart';

const _kCustomWallpaperUrl = 'privet://chat-wallpaper';

Future<void> saveCustomChatWallpaper(Uint8List bytes) async {
  await initMediaCache();
  mediaCachePin(const [_kCustomWallpaperUrl]);
  await mediaCacheWarmBytes(_kCustomWallpaperUrl, bytes);
}

Future<Uint8List?> loadCustomChatWallpaper() async {
  await initMediaCache();
  mediaCachePin(const [_kCustomWallpaperUrl]);
  return mediaCacheGet(_kCustomWallpaperUrl);
}
