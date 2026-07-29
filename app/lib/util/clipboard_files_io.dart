import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

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

Future<void> _tryPasteImage() async {
  final bytes = await RemoteInput.getClipboardImagePng();
  if (bytes == null || bytes.isEmpty) return;
  _onImage?.call(
    PickedBytes(
      bytes: bytes,
      filename: 'paste-png-${DateTime.now().millisecondsSinceEpoch}.png',
      mimeType: 'image/png',
    ),
  );
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
