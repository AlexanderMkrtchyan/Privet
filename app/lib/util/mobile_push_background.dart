import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

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
  await showMobileNotificationFromRemoteMessage(message, force: true);
}
