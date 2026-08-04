import 'package:firebase_core/firebase_core.dart';

/// Firebase options baked in at build time via --dart-define / firebase.env.
class MobilePushConfig {
  MobilePushConfig._();

  static const apiKey = String.fromEnvironment('PRIVET_FCM_API_KEY');
  static const appId = String.fromEnvironment('PRIVET_FCM_APP_ID');
  static const senderId = String.fromEnvironment('PRIVET_FCM_SENDER_ID');
  static const projectId = String.fromEnvironment('PRIVET_FCM_PROJECT_ID');

  static bool get isConfigured =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      senderId.isNotEmpty &&
      projectId.isNotEmpty;

  static FirebaseOptions get options => FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: senderId,
        projectId: projectId,
      );
}
