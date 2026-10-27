import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<File> _file() async {
  final dir = await getApplicationSupportDirectory();
  return File(p.join(dir.path, 'chat_wallpaper.jpg'));
}

Future<void> saveCustomChatWallpaper(Uint8List bytes) async {
  final file = await _file();
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
}

Future<Uint8List?> loadCustomChatWallpaper() async {
  try {
    final file = await _file();
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}
