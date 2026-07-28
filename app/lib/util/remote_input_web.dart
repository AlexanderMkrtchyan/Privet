import 'dart:typed_data';

import 'remote_input.dart';

Future<RemoteInputCapability> probe() async => const RemoteInputCapability(
      canInject: false,
      platform: 'web',
      detail:
          'Browser tabs cannot inject OS input. Use the Windows or Linux app as the controlled host.',
    );

Future<void> ensureReady() async {}

Future<void> pointerMove({
  required double x,
  required double y,
  required int displayWidth,
  required int displayHeight,
}) async {}

Future<void> pointerButton({
  required double x,
  required double y,
  required int displayWidth,
  required int displayHeight,
  required int button,
  required bool down,
}) async {}

Future<void> wheel({
  required double x,
  required double y,
  required int displayWidth,
  required int displayHeight,
  required double dx,
  required double dy,
}) async {}

Future<void> keyEvent({
  required String code,
  required bool down,
  int mods = 0,
  String? key,
}) async {}

Future<void> releaseAll() async {}

Future<String?> getClipboardText() async => null;

Future<Uint8List?> getClipboardImagePng() async => null;

Future<void> setClipboardText(String text) async {}

Future<bool> setInputLock(bool locked) async => false;
