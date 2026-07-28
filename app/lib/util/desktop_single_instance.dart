import 'desktop_single_instance_stub.dart'
    if (dart.library.io) 'desktop_single_instance_io.dart' as impl;

/// One desktop process per user session. A second launch raises the existing
/// window instead of spawning another tray icon.
abstract final class DesktopSingleInstance {
  static bool get isSupported => impl.isSupported;

  static Future<bool> ensurePrimary({void Function()? onRaise}) =>
      impl.ensurePrimary(onRaise: onRaise);

  /// Release the single-instance socket so quit can exit cleanly.
  static Future<void> shutdown() => impl.shutdown();
}
