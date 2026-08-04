import 'mobile_push_stub.dart'
    if (dart.library.io) 'mobile_push_io.dart' as impl;

/// Returns an FCM device token when Firebase is configured; otherwise null.
Future<String?> registerMobilePushToken() => impl.registerMobilePushToken();

/// Wire FCM foreground/background/tap handlers (Android/iOS native).
Future<void> attachMobilePushHandlers({
  required void Function(Map<String, String> data) onOpenPayload,
}) =>
    impl.attachMobilePushHandlers(onOpenPayload: onOpenPayload);
