import '../api/client.dart';
import '../models.dart';
import 'clipboard_files.dart';

Future<MediaUpload> uploadPicked(
  ApiClient api,
  PickedBytes file, {
  bool asVoice = false,
  void Function(double progress)? onProgress,
}) {
  return api.uploadBytes(
    bytes: file.bytes,
    filename: file.filename,
    mimeType: file.mimeType,
    asVoice: asVoice,
    onProgress: onProgress,
  );
}
