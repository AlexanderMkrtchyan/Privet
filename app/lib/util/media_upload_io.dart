import 'dart:io';

import '../api/client.dart';
import '../models.dart';
import 'clipboard_files.dart';

Future<MediaUpload> uploadPicked(
  ApiClient api,
  PickedBytes file, {
  bool asVoice = false,
  void Function(double progress)? onProgress,
}) async {
  final path = file.path;
  if (path != null && path.isNotEmpty) {
    final local = File(path);
    if (await local.exists()) {
      final length =
          file.fileSize > 0 ? file.fileSize : await local.length();
      return api.uploadStream(
        stream: _progressFileStream(local, length, onProgress),
        length: length,
        filename: file.filename,
        mimeType: file.mimeType,
        asVoice: asVoice,
        onProgress: onProgress,
      );
    }
  }
  return api.uploadBytes(
    bytes: file.bytes,
    filename: file.filename,
    mimeType: file.mimeType,
    asVoice: asVoice,
    onProgress: onProgress,
  );
}

Stream<List<int>> _progressFileStream(
  File file,
  int total,
  void Function(double progress)? onProgress,
) async* {
  var sent = 0;
  await for (final chunk in file.openRead()) {
    sent += chunk.length;
    if (total > 0) {
      onProgress?.call((sent / total * 0.97).clamp(0.0, 0.97));
    }
    yield chunk;
  }
}
