// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:js_util' as js_util;

bool _windowFocused = true;

Future<bool> requestNotificationPermission() async {
  if (!_supported) return false;
  try {
    final result = await html.Notification.requestPermission();
    return result == 'granted';
  } catch (_) {
    return false;
  }
}

bool get notificationsGranted {
  if (!_supported) return false;
  return html.Notification.permission == 'granted';
}

bool get documentHidden {
  try {
    return html.document.hidden ?? false;
  } catch (_) {
    return false;
  }
}

bool _liveDocumentHasFocus() {
  try {
    final result = js_util.callMethod(html.document, 'hasFocus', []);
    if (result is bool) return result;
  } catch (_) {}
  return _windowFocused;
}

/// True when this tab/window is actually focused (user is looking here).
///
/// Uses a live `document.hasFocus()` check — event-only tracking gets stuck
/// `true` when switching between browser windows (blur often never fires).
bool get documentHasFocus {
  _ensureFocusHooks();
  if (documentHidden) return false;
  final live = _liveDocumentHasFocus();
  _windowFocused = live;
  return live;
}

bool get _supported {
  try {
    return html.Notification.supported;
  } catch (_) {
    return false;
  }
}

bool _focusHooksInstalled = false;

void _ensureFocusHooks() {
  if (_focusHooksInstalled) return;
  _focusHooksInstalled = true;
  try {
    html.window.addEventListener('focus', (_) => _windowFocused = true);
    html.window.addEventListener('blur', (_) => _windowFocused = false);
    html.document.addEventListener('visibilitychange', (_) {
      if (documentHidden) {
        _windowFocused = false;
      } else {
        _windowFocused = _liveDocumentHasFocus();
      }
    });
  } catch (_) {}
}

void showWebNotification({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
}) {
  if (!notificationsGranted) return;
  try {
    // Use JS constructor so we can set `silent: true` — otherwise Chrome
    // plays its own notification chime (sounds like the old beep) while our
    // MP3 may be autoplay-blocked on the other account's tab.
    final opts = <String, dynamic>{
      'body': body,
      'silent': true,
    };
    if (tag != null) opts['tag'] = tag;
    final n = js_util.callConstructor(
      js_util.getProperty(html.window, 'Notification'),
      [title, js_util.jsify(opts)],
    );
    if (onClick != null) {
      js_util.callMethod(n, 'addEventListener', [
        'click',
        js_util.allowInterop((_) {
          onClick();
          js_util.callMethod(n, 'close', []);
        }),
      ]);
    }
  } catch (_) {}
}

/// Fires [callback] when the tab becomes visible / focused again.
/// Returns a disposer that removes the listeners.
void Function() onDocumentVisible(void Function() callback) {
  _ensureFocusHooks();

  void handler(html.Event _) {
    if (!documentHasFocus) return;
    callback();
  }

  html.document.addEventListener('visibilitychange', handler);
  html.window.addEventListener('focus', handler);
  return () {
    html.document.removeEventListener('visibilitychange', handler);
    html.window.removeEventListener('focus', handler);
  };
}
