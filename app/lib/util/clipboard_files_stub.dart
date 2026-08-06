import 'dart:typed_data';

import 'clipboard_files.dart';

Future<PickedBytes?> pickFileNative() async => null;

Future<List<PickedBytes>> pickMultipleFilesNative({int maxFiles = 10}) async =>
    const [];

Future<PickedBytes?> readClipboardImage() async => null;

Future<PickedBytes?> readOsClipboardImage() async => null;

int bindImagePaste(void Function(PickedBytes file) onImage) => 0;

void unbindImagePaste([int? id]) {}

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
