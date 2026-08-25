import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:image_picker/image_picker.dart';

import 'clipboard_files.dart';

/// Whether the composer should offer the "Take a picture" button. Native
/// desktop (Windows/Linux/macOS) has no camera intent, so it is hidden there;
/// Android/iOS open the system camera app and web uses a capture file input.
bool get cameraCaptureAvailable {
  if (kIsWeb) return true;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    default:
      return false;
  }
}

/// Opens the system camera ("Take a picture", Telegram/Teams-style) and
/// returns the photo as [PickedBytes] ready for the composer, or null when
/// the user cancels. Throws when no camera path exists on the platform.
Future<PickedBytes?> takePictureFromCamera() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.camera,
    // Downsample so photos send fast over the wire; image_picker re-encodes
    // to JPEG on mobile. Web ignores options it cannot apply.
    maxWidth: 2560,
    maxHeight: 2560,
    imageQuality: 85,
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;

  final mime = _sniffImageMime(bytes);
  final ext = switch (mime) {
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'png',
  };
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return PickedBytes(
    bytes: bytes,
    filename: 'IMG_${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}.$ext',
    mimeType: mime,
  );
}

String _sniffImageMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return 'image/jpeg';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/jpeg';
}
