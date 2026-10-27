import 'dart:typed_data';

Uint8List? _bytes;

Future<void> saveCustomChatWallpaper(Uint8List bytes) async {
  _bytes = bytes;
}

Future<Uint8List?> loadCustomChatWallpaper() async => _bytes;
