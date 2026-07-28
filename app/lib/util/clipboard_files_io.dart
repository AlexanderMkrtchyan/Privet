import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'clipboard_files.dart';
import 'remote_input.dart';

void Function(PickedBytes file)? _onImage;
int _pasteBindId = 0;
KeyEventCallback? _keyHandler;
var _pasteInFlight = false;

Future<PickedBytes?> pickFileNative() async => null;

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
