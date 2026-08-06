import 'dart:typed_data';

import 'clipboard_files_stub.dart'
    if (dart.library.html) 'clipboard_files_web.dart'
    if (dart.library.io) 'clipboard_files_io.dart' as impl;

class PickedBytes {
  PickedBytes({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;
}

Future<PickedBytes?> pickFileNative() => impl.pickFileNative();

Future<List<PickedBytes>> pickMultipleFilesNative({int maxFiles = 10}) =>
    impl.pickMultipleFilesNative(maxFiles: maxFiles);

/// Read a single image from the system clipboard, or null when none.
/// Call from a user gesture (context-menu Paste); never from polls.
Future<PickedBytes?> readClipboardImage() => impl.readClipboardImage();

/// OS system-clipboard image only — no in-app fallback. Returns null when the
/// OS clipboard has no image. Lets paste decide priority: image from the OS
/// clipboard wins over text, then the in-app fallbacks are consulted.
Future<PickedBytes?> readOsClipboardImage() => impl.readOsClipboardImage();

int bindImagePaste(void Function(PickedBytes file) onImage) =>
    impl.bindImagePaste(onImage);

void unbindImagePaste([int? id]) => impl.unbindImagePaste(id);

Future<Uint8List?> readBlobAsBytes(dynamic blob) =>
    impl.readBlobAsBytes(blob);

void ensureAttachFileInput() => impl.ensureAttachFileInput();

int setAttachHandlers({
  required void Function(PickedBytes file)? onPicked,
  void Function(Object error)? onError,
}) =>
    impl.setAttachHandlers(onPicked: onPicked, onError: onError);

void clearAttachHandlers([int? id]) => impl.clearAttachHandlers(id);

void positionAttachInput({
  required double left,
  required double top,
  required double width,
  required double height,
  required bool active,
}) =>
    impl.positionAttachInput(
      left: left,
      top: top,
      width: width,
      height: height,
      active: active,
    );
