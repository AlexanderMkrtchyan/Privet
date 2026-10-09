import 'dart:io';

import 'package:flutter/foundation.dart';

import 'desktop_window_present_io.dart';

bool get isDesktopCallWindowSupported =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows);

/// Flash the window to the top once when a call arrives, then immediately
/// release always-on-top so the user can freely cover Privet with other apps.
Future<void> flashDesktopWindowForIncomingCall() async {
  if (!isDesktopCallWindowSupported) return;
  try {
    await raiseDesktopWindow();
  } catch (e, st) {
    debugPrint('DesktopCallWindow: flash failed: $e\n$st');
  }
}
