import 'package:flutter/foundation.dart'
    show kIsWeb, TargetPlatform, debugPrint, defaultTargetPlatform;
import 'package:flutter/services.dart';

/// Method channel to the native incoming-call ring (Android only).
const _channel = MethodChannel('privet/incoming_call');

/// Route an incoming call into the native Teams-style full-screen ring:
/// notification with a full-screen intent into the native ring activity
/// (locked / screen off) or a call heads-up with Answer / Decline (unlocked).
/// Returns true when the native side accepted it.
Future<bool> showAndroidIncomingCall(Map<String, String> data) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    await _channel.invokeMethod<void>('showIncomingCall', data);
    return true;
  } catch (e, st) {
    debugPrint('[privet] showIncomingCall failed: $e\n$st');
    return false;
  }
}

/// Dismiss the native ring for [callId] (answered, declined, or ended
/// elsewhere) and remove its notification from the shade.
Future<void> cancelAndroidIncomingCall(String callId) async {
  if (kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      callId.isEmpty) {
    return;
  }
  try {
    await _channel.invokeMethod<void>(
      'cancelIncomingCall',
      {'callId': callId},
    );
  } catch (e, st) {
    debugPrint('[privet] cancelIncomingCall failed: $e\n$st');
  }
}

/// Read a pending call action stored by the native ring screen when the
/// Flutter engine wasn't running (app was killed). Returns a map with at
/// least `action` ("accept" | "decline") plus call payload fields, or null
/// when there is no pending action.
Future<Map<String, String>?> readPendingCallAction() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'readPendingCallAction',
    );
    if (raw == null) return null;
    return raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
  } catch (e, st) {
    debugPrint('[privet] readPendingCallAction failed: $e\n$st');
    return null;
  }
}

/// Remove the pending call action from native SharedPreferences.
Future<void> clearPendingCallAction() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _channel.invokeMethod<void>('clearPendingCallAction');
  } catch (e, st) {
    debugPrint('[privet] clearPendingCallAction failed: $e\n$st');
  }
}

/// Listen for Accept / Decline pressed on the native ring screen. The native
/// side pushes the call payload over the same channel.
void attachAndroidCallChannel({
  required void Function(Map<String, String> data) onAccept,
  required void Function(Map<String, String> data) onDecline,
}) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  _channel.setMethodCallHandler((call) async {
    final raw = call.arguments;
    final data = raw is Map
        ? raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''))
        : <String, String>{};
    switch (call.method) {
      case 'acceptCall':
        onAccept(data);
      case 'declineCall':
        onDecline(data);
    }
  });
}
