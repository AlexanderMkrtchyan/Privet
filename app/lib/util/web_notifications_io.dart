import 'dart:async';
import 'dart:io';

import 'package:desktop_notifications/desktop_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop focus / visibility for unread badges (Linux / Windows / macOS).
///
/// The web implementation uses `document.hasFocus()` / `visibilitychange`.
/// Without the same signals here, an open chat is treated as "reading" while
/// the window is in the background, so unread + tray never bump.
///
/// Linux also uses FreeDesktop notifications (same top-bar toasts as browser /
/// Teams). Windows uses [local_notifier] WinToast toasts. Android uses
/// flutter_local_notifications for WS-driven toasts.

bool _windowFocused = true;
bool _windowHidden = false;
/// Latched when we hide to the tray. [refreshDesktopFocusState] must not clear
/// this from a stale `isVisible()` read — on Windows the HWND can still report
/// visible after [windowManager.hide], which would swallow unread + tray.
bool _forceHidden = false;
bool _hooksInstalled = false;
final List<void Function()> _visibleCallbacks = [];

NotificationsClient? _notifyClient;
bool _notificationsReady = false;
bool _notificationsFailed = false;
final Map<String, int> _replaceIdsByTag = {};
final Map<String, Notification> _activeNotificationsByTag = {};

FlutterLocalNotificationsPlugin? _androidNotifications;
bool _androidReady = false;
bool _androidPermissionGranted = false;
final Map<String, void Function()> _androidClickByTag = {};
int _androidNotificationId = 1;

bool _windowsReady = false;
bool _windowsFailed = false;
final Map<String, LocalNotification> _windowsByTag = {};
final Map<String, void Function()> _windowsClickByTag = {};

bool get _isDesktop =>
    !kIsWeb &&
    (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

bool get _linuxNotifySupported => !kIsWeb && Platform.isLinux;

bool get _windowsNotifySupported => !kIsWeb && Platform.isWindows;

bool get _androidNotifySupported => !kIsWeb && Platform.isAndroid;

Future<bool> _initAndroidNotifications() async {
  if (!_androidNotifySupported) return false;
  if (_androidReady) return true;
  _androidNotifications ??= FlutterLocalNotificationsPlugin();
  const android = AndroidInitializationSettings('ic_stat_privet');
  await _androidNotifications!.initialize(
    const InitializationSettings(android: android),
    onDidReceiveNotificationResponse: (response) {
      final payload = response.payload;
      if (payload == null || payload.isEmpty) return;
      _androidClickByTag.remove(payload)?.call();
    },
  );
  final androidPlugin = _androidNotifications!
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'privet_messages',
      'Messages',
      description: 'New chat messages',
      importance: Importance.high,
    ),
  );
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'privet_calls',
      'Calls',
      description: 'Incoming calls',
      importance: Importance.max,
    ),
  );
  _androidReady = true;
  return true;
}

Future<bool> _initWindowsNotifications() async {
  if (!_windowsNotifySupported) return false;
  if (_windowsReady) return true;
  if (_windowsFailed) return false;
  try {
    // WinToast needs a Start Menu shortcut + AppUserModelID; requireCreate
    // makes one when missing so toasts actually appear.
    await localNotifier.setup(
      appName: 'Privet',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
    _windowsReady = true;
    return true;
  } catch (e, st) {
    _windowsFailed = true;
    debugPrint('windows notifications unavailable: $e\n$st');
    return false;
  }
}

Future<bool> requestNotificationPermission() async {
  if (_linuxNotifySupported) {
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
  if (_windowsNotifySupported) {
    return _initWindowsNotifications();
  }
  if (_androidNotifySupported) {
    await _initAndroidNotifications();
    final androidPlugin = _androidNotifications!
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    final granted = await androidPlugin?.requestNotificationsPermission();
    _androidPermissionGranted = granted ?? false;
    return _androidPermissionGranted;
  }
  return false;
}

bool get notificationsGranted {
  if (_linuxNotifySupported) {
    return _notificationsReady && !_notificationsFailed;
  }
  if (_windowsNotifySupported) {
    return _windowsReady && !_windowsFailed;
  }
  if (_androidNotifySupported) {
    return _androidReady && _androidPermissionGranted;
  }
  return false;
}

bool get documentHidden {
  _ensureFocusHooks();
  if (!_isDesktop) return false;
  // Tray-hide latch wins over stale HWND focus/visibility on Windows.
  return _forceHidden || _windowHidden;
}

bool get documentHasFocus {
  _ensureFocusHooks();
  if (!_isDesktop) return true;
  if (_forceHidden || _windowHidden) return false;
  return _windowFocused;
}

void showWebNotification({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
  bool isCall = false,
}) {
  if (_linuxNotifySupported) {
    unawaited(_showLinuxNotification(
      title: title,
      body: body,
      tag: tag,
      onClick: onClick,
    ));
    return;
  }
  if (_windowsNotifySupported) {
    unawaited(_showWindowsNotification(
      title: title,
      body: body,
      tag: tag,
      onClick: onClick,
    ));
    return;
  }
  if (_androidNotifySupported) {
    unawaited(_showAndroidNotification(
      title: title,
      body: body,
      tag: tag,
      onClick: onClick,
      isCall: isCall,
    ));
  }
}

Future<void> _showWindowsNotification({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
}) async {
  if (!await _initWindowsNotifications()) return;
  final id = (tag != null && tag.isNotEmpty) ? tag : 'privet';
  // Replace prior toast for the same chat so the shade doesn't stack.
  final previous = _windowsByTag.remove(id);
  if (previous != null) {
    try {
      await previous.close();
    } catch (_) {}
  }
  if (onClick != null) {
    _windowsClickByTag[id] = onClick;
  } else {
    _windowsClickByTag.remove(id);
  }
  final notification = LocalNotification(
    identifier: id,
    title: title,
    body: body.isEmpty ? ' ' : body,
    // App plays its own message chime; OS beep would double up.
    silent: true,
  );
  notification.onClick = () {
    unawaited(() async {
      await _raiseDesktopWindow();
      _windowsClickByTag[id]?.call();
    }());
  };
  _windowsByTag[id] = notification;
  try {
    await notification.show();
  } catch (e, st) {
    debugPrint('windows notification failed: $e\n$st');
  }
}

Future<void> _showAndroidNotification({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
  bool isCall = false,
}) async {
  if (!await _initAndroidNotifications()) return;
  if (!_androidPermissionGranted) {
    final ok = await requestNotificationPermission();
    if (!ok) return;
  }
  final client = _androidNotifications;
  if (client == null) return;

  final payload = (tag != null && tag.isNotEmpty) ? tag : 'privet';
  if (onClick != null) {
    _androidClickByTag[payload] = onClick;
  } else {
    _androidClickByTag.remove(payload);
  }

  final id = (tag != null && tag.isNotEmpty)
      ? tag.hashCode & 0x7fffffff
      : _androidNotificationId++;

  await client.show(
    id,
    title,
    body.isEmpty ? ' ' : body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        isCall ? 'privet_calls' : 'privet_messages',
        isCall ? 'Calls' : 'Messages',
        importance: isCall ? Importance.max : Importance.high,
        priority: isCall ? Priority.max : Priority.high,
        category: isCall
            ? AndroidNotificationCategory.call
            : AndroidNotificationCategory.message,
        fullScreenIntent: isCall,
      ),
    ),
    payload: payload,
  );
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
  // Tray-hide latch wins: do not trust a false-positive isVisible() after hide.
  if (_forceHidden) {
    _windowHidden = true;
    _windowFocused = false;
    return;
  }
  try {
    final minimized = await windowManager.isMinimized();
    final visible = await windowManager.isVisible();
    final focused = await windowManager.isFocused();
    _windowHidden = minimized || !visible;
    _windowFocused = focused && visible && !minimized;
  } catch (_) {}
}

/// Close a chat's OS notification so the dock badge cannot drift from tray.
void dismissDesktopNotification(String tag) {
  if (_linuxNotifySupported && tag.isNotEmpty) {
    final notification = _activeNotificationsByTag.remove(tag);
    _replaceIdsByTag.remove(tag);
    if (notification != null) {
      unawaited(notification.close().catchError((_) {}));
    }
  }
  if (_windowsNotifySupported && tag.isNotEmpty) {
    _windowsClickByTag.remove(tag);
    final notification = _windowsByTag.remove(tag);
    if (notification != null) {
      unawaited(notification.close().catchError((_) {}));
    }
  }
  if (_androidNotifySupported && tag.isNotEmpty) {
    _androidClickByTag.remove(tag);
    final id = tag.hashCode & 0x7fffffff;
    unawaited(_androidNotifications?.cancel(id).catchError((_) {}));
  }
}

/// Called when we hide to tray / show from tray so focus state cannot stick.
void setDesktopWindowVisible(bool visible) {
  if (!_isDesktop) return;
  _ensureFocusHooks();
  if (visible) {
    _forceHidden = false;
    _windowHidden = false;
    unawaited(() async {
      await refreshDesktopFocusState();
      _fireVisible();
    }());
  } else {
    _forceHidden = true;
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
        if (_forceHidden) {
          _windowFocused = false;
          _windowHidden = true;
          return;
        }
        final minimized = await windowManager.isMinimized();
        final focused = await windowManager.isFocused();
        final visible = await windowManager.isVisible();
        _windowFocused = focused && visible && !minimized;
        _windowHidden = minimized || !visible;
      } catch (_) {}
    }();
  } catch (e, st) {
    debugPrint('desktop focus hooks failed: $e\n$st');
  }
}

void _fireVisible() {
  if (_forceHidden || !documentHasFocus) return;
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
    // Hidden-to-tray windows can still get WM_SETFOCUS / "show" on Windows.
    // Do not treat that as the user coming back — it would mark-read +
    // skip the tray red-dot.
    if (_forceHidden) return;
    unawaited(() async {
      await refreshDesktopFocusState();
      _fireVisible();
    }());
  }

  @override
  void onWindowFocus() {
    if (_forceHidden) return;
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
        if (_forceHidden) return;
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
