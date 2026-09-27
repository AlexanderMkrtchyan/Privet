import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

const _channel = MethodChannel('privet/storage');

Future<void> requestReadMediaAccess() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _channel
        .invokeMethod<bool>('requestReadMedia')
        .timeout(const Duration(seconds: 30));
  } catch (_) {}
}
