import 'dart:io';
import 'dart:typed_data';

/// Read a recorder output path from disk (Linux / Android / desktop).
Future<Uint8List> readRecordingBytes(String path) {
  return File(path).readAsBytes();
}

Future<void> deleteRecordingFile(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {
    /* ignore */
  }
}
