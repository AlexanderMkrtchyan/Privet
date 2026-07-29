import 'dart:async';
import 'dart:io';

import 'package:desktop_notifications/desktop_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop focus / visibility for unread badges (Linux / Windows / macOS).
///
/// The web implementation uses `document.hasFocus()` / `visibilitychange`.
/// Without the same signals here, an open chat is treated as "reading" while
/// the window is in the background, so unread + tray never bump.
///
/// Linux also uses FreeDesktop notifications (same top-bar toasts as browser /
/// Teams). Windows toast support is not wired here yet.

bool _windowFocused = true;
bool _windowHidden = false;
bool _hooksInstalled = false;
final List<void Function()> _visibleCallbacks = [];

NotificationsClient? _notifyClient;
bool _notificationsReady = false;
bool _notificationsFailed = false;
final Map<String, int> _replaceIdsByTag = {};
final Map<String, Notification> _activeNotificationsByTag = {};

bool get _isDesktop =>
    !kIsWeb &&
    (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

bool get _linuxNotifySupported => !kIsWeb && Platform.isLinux;

Future<bool> requestNotificationPermission() async {
  if (!_linuxNotifySupported) return false;
  if (_notificationsReady) return true;
  if (_notificationsFailed) return false;
  try {
    final client = _notifyClient ??= NotificationsClient();
    await client.getServerInformation();
    _notificationsReady = true;
    return true;
  } catch (e, st) {
    _notificationsFailed = true;
    debugPrint('desktop notifications unavailable: $e\n$st');
    return false;
  }
}

bool get notificationsGranted =>
    _linuxNotifySupported && _notificationsReady && !_notificationsFailed;

bool get documentHidden {
  _ensureFocusHooks();
  if (!_isDesktop) return false;
  return _windowHidden;
}

bool get documentHasFocus {
  _ensureFocusHooks();
  if (!_isDesktop) return true;
  if (_windowHidden) return false;
  return _windowFocused;
}

void showWebNotification({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
}) {
  if (!_linuxNotifySupported) return;
  unawaited(_showLinuxNotification(
    title: title,
    body: body,
    tag: tag,
    onClick: onClick,
  ));
}

Future<void> _showLinuxNotification({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
}) async {
  if (!await requestNotificationPermission()) return;
  final client = _notifyClient;
  if (client == null) return;

  final replacesId =
      (tag != null && tag.isNotEmpty) ? (_replaceIdsByTag[tag] ?? 0) : 0;
  final icon = await _resolveAppIcon();

  try {
    final notification = await client.notify(
      title,
      body: body.isEmpty ? ' ' : body,
      appName: 'Privet',
      appIcon: icon,
      expireTimeoutMs: 10000,
      replacesId: replacesId,
      actions: const [NotificationAction('default', 'Open')],
      hints: [
        NotificationHint.desktopEntry('privet'),
        NotificationHint.suppressSound(),
        NotificationHint.urgency(NotificationUrgency.normal),
        NotificationHint.category(NotificationCategory('im.received')),
      ],
    );
    if (tag != null && tag.isNotEmpty) {
      _replaceIdsByTag[tag] = notification.id;
      _activeNotificationsByTag[tag] = notification;
    }

    unawaited(() async {
      try {
        final action = await notification.action;
        if (action != 'default') return;
        await _raiseDesktopWindow();
        onClick?.call();
      } catch (_) {}
    }());
  } catch (e, st) {
    debugPrint('desktop notification failed: $e\n$st');
  }
}

Future<String> _resolveAppIcon() async {
  final home = Platform.environment['HOME'] ?? '';
  final candidates = <String>[
    if (home.isNotEmpty) '$home/Apps/privet/privet.png',
    if (home.isNotEmpty) '$home/.local/share/icons/privet.png',
    '/usr/share/icons/hicolor/512x512/apps/privet.png',
  ];
  for (final path in candidates) {
    try {
      if (await File(path).exists()) return 'file://$path';
    } catch (_) {}
  }
  return '';
}

Future<void> _raiseDesktopWindow() async {
  try {
    if (Platform.isWindows) {
      try {
        await windowManager.setSkipTaskbar(false);
      } catch (_) {}
    }
    await windowManager.show();
    await windowManager.focus();
    setDesktopWindowVisible(true);
  } catch (e, st) {
    debugPrint('raise window from notification failed: $e\n$st');
  }
}

/// Fires [callback] when the desktop window becomes focused / visible again.
void Function() onDocumentVisible(void Function() callback) {
  _ensureFocusHooks();
  _visibleCallbacks.add(callback);
  return () => _visibleCallbacks.remove(callback);
}

/// Install window focus hooks early (safe to call multiple times).
void ensureDesktopFocusHooks() => _ensureFocusHooks();

/// Re-read focus/visibility from the window manager (GTK events can lie).
Future<void> refreshDesktopFocusState() async {
  if (!_isDesktop) return;
  _ensureFocusHooks();
  try {
    final visible = await windowManager.isVisible();
    final focused = await windowManager.isFocused();
    _windowHidden = !visible;
    _windowFocused = focused && visible;
  } catch (_) {}
}

/// Close a chat's OS notification so the dock badge cannot drift from tray.
void dismissDesktopNotification(String tag) {
  if (!_linuxNotifySupported || tag.isEmpty) return;
  final notification = _activeNotificationsByTag.remove(tag);
  _replaceIdsByTag.remove(tag);
  if (notification != null) {
    unawaited(notification.close().catchError((_) {}));
  }
}

/// Called when we hide to tray / show from tray so focus state cannot stick.
void setDesktopWindowVisible(bool visible) {
  if (!_isDesktop) return;
  _ensureFocusHooks();
  if (visible) {
    _windowHidden = false;
    unawaited(() async {
      await refreshDesktopFocusState();
      _fireVisible();
    }());
  } else {
    _windowHidden = true;
    _windowFocused = false;
  }
}

void _ensureFocusHooks() {
  if (_hooksInstalled || !_isDesktop) return;
  _hooksInstalled = true;
  try {
    windowManager.addListener(_DesktopFocusListener.instance);
    // Seed from the live window state when possible (events alone can miss
    // the first blur if we attach after the user already switched away).
    () async {
      try {
        final focused = await windowManager.isFocused();
        final visible = await windowManager.isVisible();
        _windowFocused = focused && visible;
        _windowHidden = !visible;
      } catch (_) {}
    }();
  } catch (e, st) {
    debugPrint('desktop focus hooks failed: $e\n$st');
  }
}

void _fireVisible() {
  if (!documentHasFocus) return;
  for (final cb in List<void Function()>.from(_visibleCallbacks)) {
    try {
      cb();
    } catch (_) {}
  }
}

class _DesktopFocusListener with WindowListener {
  _DesktopFocusListener._();
  static final instance = _DesktopFocusListener._();

  void _onWindowShown() {
    unawaited(() async {
      await refreshDesktopFocusState();
      _fireVisible();
    }());
  }

  @override
  void onWindowFocus() {
    _windowHidden = false;
    _windowFocused = true;
    _fireVisible();
  }

  @override
  void onWindowBlur() {
    _windowFocused = false;
  }

  @override
  void onWindowMinimize() {
    _windowFocused = false;
    _windowHidden = true;
  }

  @override
  void onWindowRestore() {
    _onWindowShown();
  }

  @override
  void onWindowEvent(String eventName) {
    // Linux/GTK may emit hide/show without dedicated listener hooks.
    switch (eventName) {
      case 'hide':
        _windowFocused = false;
        _windowHidden = true;
      case 'show':
        _onWindowShown();
      case 'blur':
        _windowFocused = false;
      case 'focus':
        _windowHidden = false;
        _windowFocused = true;
        _fireVisible();
      case 'minimize':
        _windowFocused = false;
        _windowHidden = true;
      case 'restore':
        _onWindowShown();
    }
  }
}
