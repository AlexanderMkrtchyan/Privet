import 'dart:typed_data';

import 'remote_input_stub.dart'
    if (dart.library.html) 'remote_input_web.dart'
    if (dart.library.io) 'remote_input_io.dart' as impl;

/// Capability + injection bridge for OS-level remote control (host side).
class RemoteInputCapability {
  const RemoteInputCapability({
    required this.canInject,
    required this.platform,
    this.backend = '',
    this.detail = '',
  });

  final bool canInject;
  final String platform;
  final String backend;
  final String detail;

  static const unsupported = RemoteInputCapability(
    canInject: false,
    platform: 'unknown',
    detail: 'Remote control host is not available on this build.',
  );
}

abstract final class RemoteInput {
  static Future<RemoteInputCapability> probe() => impl.probe();

  /// Ensure OS permissions / portal session are ready (host grant path).
  static Future<void> ensureReady() => impl.ensureReady();

  /// Absolute pointer move in normalized [0,1] display coordinates.
  static Future<void> pointerMove({
    required double x,
    required double y,
    required int displayWidth,
    required int displayHeight,
  }) =>
      impl.pointerMove(
        x: x,
        y: y,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
      );

  static Future<void> pointerButton({
    required double x,
    required double y,
    required int displayWidth,
    required int displayHeight,
    required int button,
    required bool down,
  }) =>
      impl.pointerButton(
        x: x,
        y: y,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        button: button,
        down: down,
      );

  static Future<void> wheel({
    required double x,
    required double y,
    required int displayWidth,
    required int displayHeight,
    required double dx,
    required double dy,
  }) =>
      impl.wheel(
        x: x,
        y: y,
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        dx: dx,
        dy: dy,
      );

  static Future<void> keyEvent({
    required String code,
    required bool down,
    int mods = 0,
    String? key,
  }) =>
      impl.keyEvent(code: code, down: down, mods: mods, key: key);

  static Future<void> releaseAll() => impl.releaseAll();

  static Future<String?> getClipboardText() => impl.getClipboardText();

  /// PNG bytes from the OS clipboard image, or null if none / unsupported.
  static Future<Uint8List?> getClipboardImagePng() =>
      impl.getClipboardImagePng();

  /// Writes [bytes] (any decodable image format) to the OS clipboard as an
  /// image. Returns true on success.
  static Future<bool> setClipboardImage(Uint8List bytes) =>
      impl.setClipboardImage(bytes);

  static Future<void> setClipboardText(String text) =>
      impl.setClipboardText(text);

  /// Best-effort lock of local keyboard/mouse while hosting control.
  static Future<bool> setInputLock(bool locked) => impl.setInputLock(locked);
}
