import 'mobile_push_stub.dart'
    if (dart.library.io) 'mobile_push_io.dart' as impl;

/// Returns an FCM device token when Firebase is configured; otherwise null.
Future<String?> registerMobilePushToken() => impl.registerMobilePushToken();
