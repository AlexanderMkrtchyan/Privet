import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android foreground service — keeps WS alive while logged in (Telegram-style).
class AndroidRealtimeService {
  AndroidRealtimeService._();

  static const _channel = MethodChannel('privet/realtime');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<void> start() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('start');
    } catch (e, st) {
      debugPrint('[privet] realtime service start failed: $e\n$st');
    }
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
