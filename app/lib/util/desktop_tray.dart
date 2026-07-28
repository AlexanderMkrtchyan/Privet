import 'desktop_tray_stub.dart'
    if (dart.library.io) 'desktop_tray_io.dart' as impl;

/// Close-to-tray for Linux / Windows desktop.
///
/// Closing the window hides to the system tray; tray menu (or Quit in Profile)
/// fully exits. Web / mobile are no-ops.
abstract final class DesktopTray {
  static bool get isSupported => impl.isSupported;

  /// Init window close intercept + tray icon. Call before [runApp].
  static Future<void> init() => impl.initDesktopTray();

  /// Bring the main window back and focus it.
  static Future<void> show() => impl.showDesktopWindow();

  /// Hide to tray without quitting.
  static Future<void> hideToTray() => impl.hideDesktopToTray();

  /// Destroy tray + quit the process.
  static Future<void> quit() => impl.quitDesktopApp();

  /// Reflect unread state on the tray (red-dot icon when count > 0).
  static Future<void> setUnreadCount(int count) =>
      impl.setDesktopTrayUnreadCount(count);
}
