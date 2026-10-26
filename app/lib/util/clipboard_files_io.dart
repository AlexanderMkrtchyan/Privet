import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'app_image_clipboard.dart';
import 'clipboard_files.dart';
import 'media_kind.dart';
import 'remote_input.dart';

const _imageTypeGroup = XTypeGroup(
  label: 'Images',
  extensions: ['bmp', 'dib', 'gif', 'jpeg', 'jpg', 'png', 'webp'],
  mimeTypes: [
    'image/bmp',
    'image/x-ms-bmp',
    'image/gif',
    'image/jpeg',
    'image/png',
    'image/webp',
  ],
);

void Function(PickedBytes file)? _onImage;
int _pasteBindId = 0;
KeyEventCallback? _keyHandler;
var _pasteInFlight = false;

Future<PickedBytes?> pickFileNative() async {
  final files = await pickMultipleFilesNative(maxFiles: 1);
  return files.isEmpty ? null : files.first;
}

/// GTK opens the process working directory. The Linux launcher cds into
/// ~/Apps/privet, so without this the attach dialog always starts there.
String? _pickerStartDirectory() {
  if (!Platform.isLinux) return null;
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;
  return home;
}

Future<PickedBytes?> pickImageNative() async {
  if (Platform.isLinux) {
    final file = await openFile(
      acceptedTypeGroups: const [_imageTypeGroup],
      initialDirectory: _pickerStartDirectory(),
    );
    if (file == null) return null;
    return pickedBytesFromRaw(
      bytes: null,
      path: file.path,
      filename: file.name,
    );
  }
  final result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    withData: false,
  );
  final files = result?.files;
  if (files == null || files.isEmpty) return null;
  final file = files.first;
  return pickedBytesFromRaw(
    bytes: file.bytes,
    path: file.path,
    filename: file.name,
    mimeType: mimeForFilename(file.name),
    fileSize: file.size,
  );
}

Future<PickedBytes?> pickedBytesFromRaw({
  required Uint8List? bytes,
  String? path,
  required String filename,
  String? mimeType,
  int? fileSize,
}) async {
  final name = filename.isEmpty ? 'attachment.bin' : filename;
  final mime = mimeType ?? mimeForFilename(name);
  var data = (bytes != null && bytes.isNotEmpty) ? bytes : null;
  var size = data?.length ?? fileSize ?? 0;
  String? resolvedPath = (path != null && path.isNotEmpty) ? path : null;

  if (resolvedPath != null) {
    try {
      final file = File(resolvedPath);
      if (!await file.exists()) {
        resolvedPath = null;
      } else {
        size = await file.length();
      }
    } catch (_) {
      resolvedPath = null;
    }
  }

  if (size <= 0 && data == null && resolvedPath == null) return null;
  ensureUploadFits(size);

  final kind = mediaKindFromMime(mime, filename: name);
  final loadPreview = data == null &&
      resolvedPath != null &&
      kind == 'image' &&
      size <= kMaxInMemoryAttachBytes;
  if (loadPreview) {
    try {
      data = await File(resolvedPath).readAsBytes();
      if (data.isNotEmpty) size = data.length;
    } catch (_) {
      data = null;
    }
  }

  if (data == null && resolvedPath == null) return null;
  return PickedBytes(
    bytes: data,
    path: resolvedPath,
    filename: name,
    mimeType: mime,
    fileSize: size,
  );
}

Future<List<PickedBytes>> pickMultipleFilesNative({int maxFiles = 10}) async {
  FileTooLargeException? tooLarge;
  if (Platform.isLinux) {
    final files = await openFiles(initialDirectory: _pickerStartDirectory());
    final out = <PickedBytes>[];
    for (final file in files) {
      if (out.length >= maxFiles) break;
      try {
        final picked = await pickedBytesFromRaw(
          bytes: null,
          path: file.path,
          filename: file.name,
        );
        if (picked != null) out.add(picked);
      } on FileTooLargeException catch (e) {
        tooLarge = e;
      }
    }
    if (out.isEmpty && tooLarge != null) throw tooLarge;
    return out;
  }
  // Never withData: true — Android copies the whole video into RAM and
  // dies when the user picks from Downloads / Videos.
  final result = await FilePicker.platform.pickFiles(
    withData: false,
    type: FileType.any,
    allowMultiple: maxFiles > 1,
  );
  if (result == null || result.files.isEmpty) return const [];
  final out = <PickedBytes>[];
  for (final file in result.files) {
    if (out.length >= maxFiles) break;
    try {
      final picked = await pickedBytesFromRaw(
        bytes: file.bytes,
        path: file.path,
        filename: file.name,
        fileSize: file.size,
      );
      if (picked != null) out.add(picked);
    } on FileTooLargeException catch (e) {
      tooLarge = e;
    }
  }
  if (out.isEmpty && tooLarge != null) throw tooLarge;
  return out;
}

int bindImagePaste(void Function(PickedBytes file) onImage) {
  final id = ++_pasteBindId;
  unbindImagePaste();
  _onImage = onImage;
  _keyHandler = (KeyEvent event) {
    if (id != _pasteBindId) return false;
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyV) return false;
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) return false;
    if (!_pasteInFlight) {
      _pasteInFlight = true;
      unawaited(_tryPasteImage().whenComplete(() => _pasteInFlight = false));
    }
    return false; // let text paste proceed when clipboard has text
  };
  HardwareKeyboard.instance.addHandler(_keyHandler!);
  return id;
}

void unbindImagePaste([int? id]) {
  if (id != null && id != _pasteBindId) return;
  if (_keyHandler != null) {
    HardwareKeyboard.instance.removeHandler(_keyHandler!);
    _keyHandler = null;
  }
  _onImage = null;
}

Future<PickedBytes?> readOsClipboardImage() async {
  final bytes = await RemoteInput.getClipboardImagePng();
  if (bytes == null || bytes.isEmpty) return null;
  return _pickedFromBytes(bytes);
}

Future<PickedBytes?> readClipboardImage() async {
  final os = await readOsClipboardImage();
  if (os != null) return os;
  // Fallback: in-app image clipboard for platforms without native image
  // clipboard support (e.g. iOS where the remote_input channel is absent).
  // Only use it while the copied image is still the clipboard's latest
  // content — if the OS clipboard now holds text, a newer copy superseded the
  // image and this fallback would paste the stale image alongside that text
  // on every Ctrl+V.
  if (await _osClipboardHasText()) return null;
  final appBytes = peekCopiedImage();
  if (appBytes != null) return _pickedFromBytes(appBytes);
  return null;
}

/// Whether the OS clipboard currently holds non-empty text.
Future<bool> _osClipboardHasText() async {
  try {
    final text = await RemoteInput.getClipboardText();
    if (text != null && text.isNotEmpty) return true;
  } catch (_) {}
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain)
        .timeout(const Duration(milliseconds: 300));
    return data?.text?.isNotEmpty ?? false;
  } catch (_) {
    return false;
  }
}

/// Wraps raw image bytes with the correct MIME + filename from the magic
/// bytes, so pasted images survive regardless of the source format.
PickedBytes _pickedFromBytes(Uint8List bytes) {
  final mime = sniffImageMime(bytes);
  final ext = imageExtensionForMime(mime);
  return PickedBytes(
    bytes: bytes,
    filename: 'paste-$ext-${DateTime.now().millisecondsSinceEpoch}.$ext',
    mimeType: mime,
  );
}

Future<void> _tryPasteImage() async {
  final picked = await readClipboardImage();
  if (picked != null) _onImage?.call(picked);
}

Future<Uint8List?> readBlobAsBytes(dynamic blob) async => null;

void ensureAttachFileInput() {}

int setAttachHandlers({
  required void Function(PickedBytes file)? onPicked,
  void Function(Object error)? onError,
}) =>
    0;

void clearAttachHandlers([int? id]) {}

void positionAttachInput({
  required double left,
  required double top,
  required double width,
  required double height,
  required bool active,
}) {}
