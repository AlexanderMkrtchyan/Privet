import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// Ubuntu / GNOME dock badge via Unity LauncherEntry D-Bus API.
///
/// GNOME dock otherwise infers badge counts from stacked desktop notifications,
/// which drifts from [PrivetState.totalUnreadCount] used by the tray icon.

bool get isLauncherBadgeSupported => !kIsWeb && Platform.isLinux;

DBusClient? _sessionBus;
bool _busFailed = false;

/// Desktop id from `privet.desktop` (see scripts/build-linux.sh).
const _launcherAppUri = 'application://privet.desktop';

Future<DBusClient?> _bus() async {
  if (_busFailed) return null;
  final existing = _sessionBus;
  if (existing != null) return existing;
  try {
    final bus = DBusClient.session();
    _sessionBus = bus;
    return bus;
  } catch (e, st) {
    _busFailed = true;
    debugPrint('LauncherBadge: session bus unavailable: $e\n$st');
    return null;
  }
}

Future<void> setDesktopLauncherUnreadCount(int count) async {
  if (!isLauncherBadgeSupported) return;
  final bus = await _bus();
  if (bus == null) return;

  final n = count < 0 ? 0 : count;
  final visible = n > 0;
  try {
    await bus.emitSignal(
      path: DBusObjectPath('/com/canonical/Unity/LauncherEntry'),
      interface: 'com.canonical.Unity.LauncherEntry',
      name: 'Update',
      values: [
        DBusString(_launcherAppUri),
        DBusDict.stringVariant({
          'count': DBusInt32(n),
          'count-visible': DBusBoolean(visible),
        }),
      ],
    );
  } catch (e, st) {
    debugPrint('LauncherBadge: Update failed: $e\n$st');
  }
}
