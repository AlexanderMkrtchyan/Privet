import 'dart:typed_data';

import 'clipboard_files_stub.dart'
    if (dart.library.html) 'clipboard_files_web.dart'
    if (dart.library.io) 'clipboard_files_io.dart' as impl;

class PickedBytes {
  PickedBytes({
    Uint8List? bytes,
    this.path,
    required this.filename,
    required this.mimeType,
    int? fileSize,
  })  : bytes = bytes ?? Uint8List(0),
        fileSize = fileSize ?? bytes?.length ?? 0;

  /// In-memory payload for small items (photos, voice, paste). Empty when
  /// [path] is the source of truth — large videos must not be loaded here.
  final Uint8List bytes;
  final String? path;
  final String filename;
  final String mimeType;
  final int fileSize;

  bool get hasPreviewBytes => bytes.isNotEmpty;
}

/// Builds a [PickedBytes] from FilePicker output. On desktop, [bytes] is
/// often empty even when [path] is set — read the file in that case.
Future<PickedBytes?> pickedBytesFromRaw({
  required Uint8List? bytes,
  String? path,
  required String filename,
  String? mimeType,
  int? fileSize,
}) =>
    impl.pickedBytesFromRaw(
      bytes: bytes,
      path: path,
      filename: filename,
      mimeType: mimeType,
      fileSize: fileSize,
    );

Future<PickedBytes?> pickFileNative() => impl.pickFileNative();

Future<List<PickedBytes>> pickMultipleFilesNative({int maxFiles = 10}) =>
    impl.pickMultipleFilesNative(maxFiles: maxFiles);

Future<PickedBytes?> pickImageNative() => impl.pickImageNative();

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
