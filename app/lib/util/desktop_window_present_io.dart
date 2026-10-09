import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

const _channel = MethodChannel('privet/window');

/// Map and focus the desktop window.
///
/// On Linux, [activationToken] is the xdg-activation / startup-notification id
/// from a notification click or a second launch. GNOME 50 ignores
/// [WindowManager.focus] unless that token is applied first.
Future<void> raiseDesktopWindow({String? activationToken}) async {
  if (Platform.isWindows) {
    try {
      await windowManager.setSkipTaskbar(false);
    } catch (e, st) {
      debugPrint('raiseDesktopWindow: setSkipTaskbar failed: $e\n$st');
    }
  }
  if (Platform.isLinux) {
    try {
      final token = activationToken?.trim();
      final ok = await _channel.invokeMethod<bool>('present', {
        if (token != null && token.isNotEmpty) 'token': token,
      });
      if (ok == true) return;
    } catch (e, st) {
      debugPrint('raiseDesktopWindow: native present failed: $e\n$st');
    }
  }
  try {
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(false);
  } catch (e, st) {
    debugPrint('raiseDesktopWindow: window_manager present failed: $e\n$st');
  }
}
