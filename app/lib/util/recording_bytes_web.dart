import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// On web, [path] is a blob: URL from MediaRecorder.
Future<Uint8List> readRecordingBytes(String path) async {
  final res = await http.get(Uri.parse(path));
  return res.bodyBytes;
}

Future<void> deleteRecordingFile(String path) async {
  // blob: URLs are revoked by the record package; nothing to delete.
}
