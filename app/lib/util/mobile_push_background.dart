import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mobile_push_config.dart';
import 'mobile_push_notifications.dart';

/// Background/killed-app FCM handler — must stay a top-level function.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!MobilePushConfig.isConfigured) return;
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: MobilePushConfig.options);
  }
  await initMobileNotificationPlugin();
  final isCall = message.data['type'] == 'call.incoming';
  if (isCall) {
    // Killed/backgrounded-app calls land here, NOT in the native
    // PrivetFCMService: GMS delivers background messages to this handler via
    // the C2DM broadcast receiver, so the MESSAGING_EVENT service is never
    // woken. Post the Teams-style full-screen call ring ourselves.
    final prefs = await SharedPreferences.getInstance();
    final callId = message.data['callId'] ?? '';
    if (callId.isNotEmpty) {
      // The WebSocket path may already have posted the native ring (marker
      // written by _showAndroidIncomingRing) — don't stack a second ring.
      if (prefs.getBool('native_call_handled_$callId') ?? false) return;
      // Stash the payload so the ring materializes on the next cold start
      // even if the notification launch is not replayed (the Flutter engine
      // may still be booting when the full-screen intent fires).
      await prefs.setString(
        'pending_incoming_call',
        encodeCallNotificationPayload(message.data),
      );
      await prefs.setInt(
        'pending_incoming_call_at',
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    await showMobileNotificationFromRemoteMessage(message, force: true);
    return;
  }
  // Regular messages carry a `notification` block the OS posts itself, so
  // posting our own local copy would double the toast.
  if (message.notification != null) return;
  await showMobileNotificationFromRemoteMessage(message, force: true);
}
