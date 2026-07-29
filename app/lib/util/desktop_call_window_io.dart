import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

bool get isDesktopCallWindowSupported =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows);

/// Flash the window to the top once when a call arrives, then immediately
/// release always-on-top so the user can freely cover Privet with other apps.
Future<void> flashDesktopWindowForIncomingCall() async {
  if (!isDesktopCallWindowSupported) return;
  try {
    if (!await windowManager.isVisible()) {
      if (Platform.isWindows) {
        await windowManager.setSkipTaskbar(false);
      }
    }
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(false);
  } catch (e, st) {
    debugPrint('DesktopCallWindow: flash failed: $e\n$st');
  }
}
