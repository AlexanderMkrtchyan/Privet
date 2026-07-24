import 'package:flutter/foundation.dart';

/// Mobile push uses FCM when Firebase options are passed via dart-define:
///   --dart-define=PRIVET_FCM_API_KEY=...
///   --dart-define=PRIVET_FCM_APP_ID=...
///   --dart-define=PRIVET_FCM_SENDER_ID=...
///   --dart-define=PRIVET_FCM_PROJECT_ID=...
///
/// Without those, this returns null and the app still works (WS notify only).
/// Wire firebase_messaging once you have a Firebase project — see server/.env.example.
Future<String?> registerMobilePushToken() async {
  if (kIsWeb) return null;
  const apiKey = String.fromEnvironment('PRIVET_FCM_API_KEY');
  const appId = String.fromEnvironment('PRIVET_FCM_APP_ID');
  const senderId = String.fromEnvironment('PRIVET_FCM_SENDER_ID');
  const projectId = String.fromEnvironment('PRIVET_FCM_PROJECT_ID');
  if (apiKey.isEmpty ||
      appId.isEmpty ||
      senderId.isEmpty ||
      projectId.isEmpty) {
    return null;
  }
  // Firebase packages are optional until credentials exist — keep build green.
  // When ready: add firebase_core + firebase_messaging and initialize here.
  debugPrint(
    '[privet] FCM dart-defines present; add firebase_messaging to enable push.',
  );
  return null;
}
