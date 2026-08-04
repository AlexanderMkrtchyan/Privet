import 'package:flutter/foundation.dart';

/// True when the Flutter UI is in the foreground (not paused/hidden).
bool mobileAppInForeground = true;

void setMobileAppInForeground(bool value) {
  mobileAppInForeground = value;
}

/// Skip duplicate toast when WS and FCM both deliver the same event.
final Set<String> _recentNotificationKeys = <String>{};

bool shouldSuppressMobileNotification(String key) {
  if (!mobileAppInForeground) return false;
  if (_recentNotificationKeys.contains(key)) return true;
  _recentNotificationKeys.add(key);
  Future<void>.delayed(const Duration(seconds: 4), () {
    _recentNotificationKeys.remove(key);
  });
  return false;
}
