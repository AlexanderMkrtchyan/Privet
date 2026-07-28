import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_single_instance_io.dart' show shutdown;
import 'web_notifications_io.dart'
    show ensureDesktopFocusHooks, setDesktopWindowVisible;

bool get isSupported =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows);

Future<void> initDesktopTray() async {
  if (!isSupported) return;
  await windowManager.ensureInitialized();
  // setSkipTaskbar (used when hiding/showing) needs ITaskbarList3 on Windows.
  await windowManager.waitUntilReadyToShow();
  await windowManager.setPreventClose(true);
  ensureDesktopFocusHooks();
  _DesktopTrayHost.instance.attach();
  await _DesktopTrayHost.instance.ensureTray();
}

Future<void> showDesktopWindow() => _DesktopTrayHost.instance.showWindow();

Future<void> hideDesktopToTray() => _DesktopTrayHost.instance.hideToTray();

Future<void> quitDesktopApp() => _DesktopTrayHost.instance.quit();

Future<void> setDesktopTrayUnreadCount(int count) =>
    _DesktopTrayHost.instance.setUnreadCount(count);

class _DesktopTrayHost with WindowListener, TrayListener {
  _DesktopTrayHost._();
  static final instance = _DesktopTrayHost._();

  bool _attached = false;
  bool _trayReady = false;
  bool _menuReady = false;
  bool _quitting = false;
  String? _iconPath;
  String? _unreadIconPath;
  int _unreadCount = 0;
  bool _showingUnreadIcon = false;
  Menu? _trayMenu;

  void attach() {
    if (_attached) return;
    _attached = true;
    windowManager.addListener(this);
    trayManager.addListener(this);
  }

  /// Built once — rebuilding the GTK/AppIndicator menu on every unread tick
  /// assigns new item ids and breaks Quit clicks on an open menu.
  Menu _contextMenu() {
    return _trayMenu ??= Menu(
      items: [
        MenuItem(
          key: 'show',
          label: 'Open Privet',
          onClick: (_) => showWindow(),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Quit Privet',
          onClick: (_) => quit(),
        ),
      ],
    );
  }

  Future<void> _ensureContextMenu() async {
    if (_menuReady) return;
    try {
      await trayManager.setContextMenu(_contextMenu());
      _menuReady = true;
    } catch (e, st) {
      debugPrint('DesktopTray: setContextMenu failed: $e\n$st');
    }
  }

  Future<void> ensureTray() async {
    if (_trayReady) return;
    try {
      _iconPath = await _resolveIconPath(unread: false);
      _unreadIconPath = await _resolveIconPath(unread: true);
      await trayManager.setIcon(_iconPath!);
      _showingUnreadIcon = false;
      await _ensureContextMenu();
      await _applyUnreadChrome(force: true);
      _trayReady = true;
    } catch (e, st) {
      debugPrint('DesktopTray: tray init failed: $e\n$st');
    }
  }

  Future<void> setUnreadCount(int count) async {
    if (!isSupported) return;
    final next = count < 0 ? 0 : count;
    if (_trayReady && next == _unreadCount) return;
    _unreadCount = next;
    await ensureTray();
    if (!_trayReady) return;
    await _applyUnreadChrome();
  }

  Future<void> _applyUnreadChrome({bool force = false}) async {
    final hasUnread = _unreadCount > 0;

    if (force || hasUnread != _showingUnreadIcon) {
      final path = hasUnread
          ? (_unreadIconPath ?? _iconPath)
          : _iconPath;
      if (path != null) {
        try {
          await trayManager.setIcon(path);
          _showingUnreadIcon = hasUnread;
        } catch (e, st) {
          debugPrint('DesktopTray: setIcon failed: $e\n$st');
        }
      }
    }

    final tip = hasUnread ? 'Privet — unread messages' : 'Privet';
    if (Platform.isWindows) {
      try {
        await trayManager.setToolTip(tip);
      } catch (_) {}
    }
    if (Platform.isLinux) {
      try {
        await trayManager.setTitle('');
      } catch (_) {}
    }
  }

  Future<String> _resolveIconPath({required bool unread}) async {
    final cached = unread ? _unreadIconPath : _iconPath;
    if (cached != null) return cached;

    final fileName = unread
        ? (Platform.isWindows ? 'tray-unread.ico' : 'tray-unread.png')
        : (Platform.isWindows ? 'tray.ico' : 'tray.png');
    final assetName = unread
        ? (Platform.isWindows
            ? 'assets/icons/tray-unread.ico'
            : 'assets/icons/tray-unread.png')
        : (Platform.isWindows
            ? 'assets/icons/tray.ico'
            : 'assets/icons/tray.png');

    // Prefer the dedicated tray asset (zoomed mark). Do not fall back to the
    // full app icon first — its padding makes the tray glyph look tiny.
    try {
      final exe = Platform.resolvedExecutable;
      final beside = [
        if (Platform.isLinux) ...[
          p.join(p.dirname(exe), 'data', 'flutter_assets', 'assets', 'icons',
              fileName),
          p.join(p.dirname(exe), fileName),
        ],
        if (Platform.isWindows) ...[
          p.join(p.dirname(exe), 'data', 'flutter_assets', 'assets', 'icons',
              fileName),
          if (!unread) p.join(p.dirname(exe), 'app_icon.ico'),
        ],
      ];
      for (final path in beside) {
        if (await File(path).exists()) return path;
      }
    } catch (_) {}

    // Fall back: extract bundled asset to a stable cache file.
    final data = await rootBundle.load(assetName);
    final bytes = data.buffer.asUint8List();
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, fileName));
    if (!await file.exists() || (await file.length()) != bytes.length) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.path;
  }

  Future<void> showWindow() async {
    if (_quitting) return;
    await ensureTray();
    if (Platform.isWindows) {
      try {
        await windowManager.setSkipTaskbar(false);
      } catch (e, st) {
        debugPrint('DesktopTray: setSkipTaskbar(false) failed: $e\n$st');
      }
    }
    await windowManager.show();
    await windowManager.focus();
    setDesktopWindowVisible(true);
  }

  Future<void> hideToTray() async {
    if (_quitting) return;
    await ensureTray();
    // Drop from the taskbar while in tray (Windows); Linux ignores harmlessly.
    if (Platform.isWindows) {
      try {
        await windowManager.setSkipTaskbar(true);
      } catch (e, st) {
        debugPrint('DesktopTray: setSkipTaskbar(true) failed: $e\n$st');
      }
    }
    setDesktopWindowVisible(false);
    await windowManager.hide();
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await shutdown();
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      if (_trayReady) {
        await trayManager.destroy();
        _trayReady = false;
      }
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    unawaited(hideToTray());
  }

  @override
  void onTrayIconMouseDown() {
    if (_quitting) return;
    if (Platform.isLinux) {
      // AppIndicator owns left-click → native GTK menu (Quit lives there).
      return;
    }
    // Windows / macOS: left-click raises the window; right-click opens menu.
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    if (_quitting) return;
    if (Platform.isWindows) {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'quit':
        unawaited(quit());
    }
  }
}
