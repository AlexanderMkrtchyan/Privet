import 'desktop_launcher_badge_stub.dart'
    if (dart.library.io) 'desktop_launcher_badge_io.dart' as impl;

/// GNOME / Ubuntu dock unread badge (Unity LauncherEntry).
abstract final class DesktopLauncherBadge {
  static bool get isSupported => impl.isLauncherBadgeSupported;

  static Future<void> setUnreadCount(int count) =>
      impl.setDesktopLauncherUnreadCount(count);
}
