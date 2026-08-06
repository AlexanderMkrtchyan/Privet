import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'remote_input.dart';

const _channel = MethodChannel('privet/remote_input');

Future<RemoteInputCapability> probe() async {
  if (!(Platform.isWindows || Platform.isLinux)) {
    return RemoteInputCapability(
      canInject: false,
      platform: Platform.operatingSystem,
      detail: 'Remote control host requires Windows or Linux desktop.',
    );
  }
  try {
    final raw = await _channel.invokeMethod<Map>('probe');
    if (raw == null) return RemoteInputCapability.unsupported;
    return RemoteInputCapability(
      canInject: raw['canInject'] == true,
      platform: (raw['platform'] as String?) ?? Platform.operatingSystem,
      backend: (raw['backend'] as String?) ?? '',
      detail: (raw['detail'] as String?) ?? '',
    );
  } on MissingPluginException {
    return RemoteInputCapability(
      canInject: false,
      platform: Platform.operatingSystem,
      detail: 'Native remote-input plugin is not registered.',
    );
  } catch (e) {
    return RemoteInputCapability(
      canInject: false,
      platform: Platform.operatingSystem,
      detail: '$e',
    );
  }
}

Future<void> ensureReady() async {
  await _channel.invokeMethod('ensureReady');
}

Future<void> pointerMove({
  required double x,
  required double y,
  required int displayWidth,
  required int displayHeight,
}) async {
  await _channel.invokeMethod('pointerMove', {
    'x': x,
    'y': y,
    'w': displayWidth,
    'h': displayHeight,
  });
}

Future<void> pointerButton({
  required double x,
  required double y,
  required int displayWidth,
  required int displayHeight,
  required int button,
  required bool down,
}) async {
  await _channel.invokeMethod('pointerButton', {
    'x': x,
    'y': y,
    'w': displayWidth,
    'h': displayHeight,
    'button': button,
    'down': down,
  });
}

Future<void> wheel({
  required double x,
  required double y,
  required int displayWidth,
  required int displayHeight,
  required double dx,
  required double dy,
}) async {
  await _channel.invokeMethod('wheel', {
    'x': x,
    'y': y,
    'w': displayWidth,
    'h': displayHeight,
    'dx': dx,
    'dy': dy,
  });
}

Future<void> keyEvent({
  required String code,
  required bool down,
  int mods = 0,
  String? key,
}) async {
  await _channel.invokeMethod('keyEvent', {
    'code': code,
    'down': down,
    'mods': mods,
    if (key != null) 'key': key,
  });
}

Future<void> releaseAll() async {
  await _channel.invokeMethod('releaseAll');
}

Future<String?> getClipboardText() async {
  try {
    final text = await _channel.invokeMethod<String>('getClipboardText');
    return text;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> getClipboardImagePng() async {
  try {
    final raw = await _channel.invokeMethod<dynamic>('getClipboardImagePng');
    if (raw == null) return null;
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return null;
  } catch (_) {
    return null;
  }
}

Future<void> setClipboardText(String text) async {
  try {
    await _channel.invokeMethod('setClipboardText', {'text': text});
  } catch (_) {}
}

Future<bool> setClipboardImage(Uint8List bytes) async {
  try {
    final ok = await _channel.invokeMethod<bool>('setClipboardImage', {
      'png': bytes,
    });
    return ok == true;
  } catch (_) {
    return false;
  }
}

Future<bool> setInputLock(bool locked) async {
  try {
    final ok = await _channel.invokeMethod<bool>('setInputLock', {
      'locked': locked,
    });
    return ok == true;
  } catch (_) {
    return false;
  }
}
