import 'desktop_single_instance_stub.dart'
    if (dart.library.io) 'desktop_single_instance_io.dart' as impl;

/// One desktop process per user session. A second launch raises the existing
/// window instead of spawning another tray icon.
abstract final class DesktopSingleInstance {
  static bool get isSupported => impl.isSupported;

  static Future<bool> ensurePrimary({
    void Function(String? activationToken)? onRaise,
  }) =>
      impl.ensurePrimary(onRaise: onRaise);

  /// Quit a second launch. `return` from `main` does not stop the GTK loop.
  static void exitSecondary() => impl.exitSecondary();

  /// Release the single-instance socket so quit can exit cleanly.
  static Future<void> shutdown() => impl.shutdown();
}
