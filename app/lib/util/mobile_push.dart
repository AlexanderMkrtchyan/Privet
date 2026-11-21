import 'mobile_push_stub.dart'
    if (dart.library.io) 'mobile_push_io.dart' as impl;

/// Returns an FCM device token when Firebase is configured; otherwise null.
Future<String?> registerMobilePushToken() => impl.registerMobilePushToken();

/// Wire FCM foreground/background/tap handlers (Android/iOS native).
Future<void> attachMobilePushHandlers({
  required void Function(Map<String, String> data) onOpenPayload,
  void Function(String actionId, Map<String, String> data)? onAction,
  /// Called for every normal message push that arrives while the app runs.
  /// The server sends FCM even when a socket is registered, so this is the
  /// only signal that survives a silently dead WebSocket.
  void Function(Map<String, String> data)? onMessage,
}) =>
    impl.attachMobilePushHandlers(
      onOpenPayload: onOpenPayload,
      onAction: onAction,
      onMessage: onMessage,
    );
