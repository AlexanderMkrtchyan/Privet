import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android realtime channel — legacy stop hook for older "Online" FG service.
///
/// We no longer start a persistent foreground notification; FCM delivers
/// messages and calls while the app is backgrounded. [stop] clears leftovers.
class AndroidRealtimeService {
  AndroidRealtimeService._();

  static const _channel = MethodChannel('privet/realtime');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<void> start() async {
    // No-op — see class doc. Still invoke native stop so upgrades clear the
    // old shade notification immediately on login.
    await stop();
  }

  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// Opens the system dialog so Android won't kill Privet in the background.
  static Future<bool> requestBatteryExemption() async {
    if (!supported) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('requestBatteryExemption');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
