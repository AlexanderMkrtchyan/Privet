import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'app_image_clipboard.dart';
import 'clipboard_files.dart';
import 'remote_input.dart';

void Function(PickedBytes file)? _onImage;
int _pasteBindId = 0;
KeyEventCallback? _keyHandler;
var _pasteInFlight = false;

Future<PickedBytes?> pickFileNative() async => null;

Future<List<PickedBytes>> pickMultipleFilesNative({int maxFiles = 10}) async {
  final result = await FilePicker.platform.pickFiles(
    withData: true,
    type: FileType.any,
    allowMultiple: true,
  );
  if (result == null || result.files.isEmpty) return const [];
  final out = <PickedBytes>[];
  for (final file in result.files) {
    if (out.length >= maxFiles) break;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) continue;
    out.add(PickedBytes(
      bytes: bytes,
      filename: file.name,
      mimeType: _mimeFor(file.name),
    ));
  }
  return out;
}

String _mimeFor(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  return 'application/octet-stream';
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
  final mime = _sniffImageMime(bytes);
  final ext = switch (mime) {
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'png',
  };
  return PickedBytes(
    bytes: bytes,
    filename: 'paste-$ext-${DateTime.now().millisecondsSinceEpoch}.$ext',
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
  return 'image/png';
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
