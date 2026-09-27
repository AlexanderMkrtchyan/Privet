import '../api/client.dart';
import '../models.dart';
import 'clipboard_files.dart';

import 'media_upload_stub.dart'
    if (dart.library.io) 'media_upload_io.dart' as impl;

/// Uploads [file] from disk when [PickedBytes.path] is set, otherwise from
/// the in-memory bytes. Large videos must take the path path.
Future<MediaUpload> uploadPicked(
  ApiClient api,
  PickedBytes file, {
  bool asVoice = false,
  void Function(double progress)? onProgress,
}) =>
    impl.uploadPicked(
      api,
      file,
      asVoice: asVoice,
      onProgress: onProgress,
    );
