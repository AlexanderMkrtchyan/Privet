import 'fullscreen_stub.dart'
    if (dart.library.html) 'fullscreen_web.dart' as impl;

/// Browser / window fullscreen helpers for immersive remote control.
abstract final class PrivetFullscreen {
  static Future<void> enter() => impl.enterFullscreen();

  static Future<void> exit() => impl.exitFullscreen();

  static Future<void> toggle() async {
    if (isFullscreen) {
      await exit();
    } else {
      await enter();
    }
  }

  static bool get isFullscreen => impl.isFullscreen();
}
