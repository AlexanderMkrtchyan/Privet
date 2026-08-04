import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'mobile_push_config.dart';
import 'mobile_push_notifications.dart';

bool _firebaseReady = false;

Future<void> _ensureFirebase() async {
  if (_firebaseReady) return;
  if (!MobilePushConfig.isConfigured) return;
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: MobilePushConfig.options);
  }
  _firebaseReady = true;
}

/// Register for FCM and return the device token (null when Firebase not configured).
Future<String?> registerMobilePushToken() async {
  if (kIsWeb || !MobilePushConfig.isConfigured) return null;
  try {
    await _ensureFirebase();
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: true,
    );
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    final token = await messaging.getToken();
    debugPrint('[privet] FCM token registered (${token?.length ?? 0} chars)');
    return token;
  } catch (e, st) {
    debugPrint('[privet] FCM register failed: $e\n$st');
    return null;
  }
}

/// Wire foreground + tap handlers after [PrivetState] is ready.
Future<void> attachMobilePushHandlers({
  required void Function(Map<String, String> data) onOpenPayload,
}) async {
  if (kIsWeb || !MobilePushConfig.isConfigured) return;
  try {
    await _ensureFirebase();
    await initMobileNotificationPlugin(onTap: (payload) {
      onOpenPayload(_payloadToMap(payload));
    });

    FirebaseMessaging.onMessage.listen((message) async {
      await showMobileNotificationFromRemoteMessage(
        message,
        force: message.data['type'] == 'call.incoming',
      );
      onOpenPayload(_stringifyData(message.data));
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      onOpenPayload(_stringifyData(message.data));
    });

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      onOpenPayload(_stringifyData(initial.data));
    }

    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      debugPrint('[privet] FCM token refreshed');
      // PrivetState re-registers on next resume via initMobilePush().
    });
  } catch (e, st) {
    debugPrint('[privet] attachMobilePushHandlers failed: $e\n$st');
  }
}

Map<String, String> _payloadToMap(String? payload) {
  if (payload == null || payload.isEmpty) return const {};
  final out = <String, String>{};
  for (final part in payload.split('|')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    out[part.substring(0, idx)] = part.substring(idx + 1);
  }
  return out;
}

Map<String, String> _stringifyData(Map<String, dynamic> data) {
  return data.map((k, v) => MapEntry(k, v?.toString() ?? ''));
}

String encodeNotificationPayload(Map<String, String> data) {
  return data.entries.map((e) => '${e.key}=${e.value}').join('|');
}
