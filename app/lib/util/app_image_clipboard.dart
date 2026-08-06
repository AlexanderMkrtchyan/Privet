import 'dart:typed_data';

/// In-app image clipboard — holds the last image bytes that were copied
/// from a chat message. Used as a fallback on platforms where the OS
/// clipboard does not have native image support (Android, etc.), so paste
/// can still retrieve a recently copied image.
Uint8List? _lastImage;

void rememberCopiedImage(Uint8List bytes) {
  _lastImage = bytes;
}

Uint8List? peekCopiedImage() => _lastImage;

void clearCopiedImage() {
  _lastImage = null;
}
