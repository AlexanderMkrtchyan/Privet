import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'mobile_app_lifecycle.dart';
import 'mobile_push_io.dart';

FlutterLocalNotificationsPlugin? _plugin;
bool _pluginReady = false;

const _fsiChannel = MethodChannel('privet/notifications');

/// Android 14+ blocks full-screen call intents until the user flips the
/// "Full-screen notifications" switch for this app. Prompt once when it is
/// still off so incoming calls can launch the Accept/Decline screen.
Future<void> requestMobileFullScreenIntent() async {
  try {
    await _fsiChannel.invokeMethod<void>('requestFullScreenIntent');
  } catch (e, st) {
    debugPrint('[privet] full-screen intent request failed: $e\n$st');
  }
}

/// Whether the OS is currently allowed to post notifications for this app.
/// Android only — non-Android returns true (nothing to check).
Future<bool> mobileNotificationsEnabled() async {
  try {
    return await _fsiChannel.invokeMethod<bool>('notificationsEnabled') ?? true;
  } catch (e, st) {
    debugPrint('[privet] notifications-enabled check failed: $e\n$st');
    return true;
  }
}

/// Open this app's notification settings page so the user can re-enable
/// notifications after denying the one-time system dialog (which Android
/// never re-shows). Returns true if the settings page was opened.
Future<bool> openMobileNotificationSettings() async {
  try {
    return await _fsiChannel.invokeMethod<bool>('openNotificationSettings') ??
        false;
  } catch (e, st) {
    debugPrint('[privet] open notification settings failed: $e\n$st');
    return false;
  }
}

/// Small-icon resource: a monochrome "P" (status-bar-safe). The full-color
/// launcher icon renders as a white square in the shade.
const _privetNotificationIcon = 'ic_stat_privet';

Future<void> initMobileNotificationPlugin({
  void Function(String? payload)? onTap,
  void Function(String actionId, String? payload)? onAction,
}) async {
  if (_pluginReady && onTap == null && onAction == null) return;
  _plugin ??= FlutterLocalNotificationsPlugin();
  const android = AndroidInitializationSettings(_privetNotificationIcon);
  await _plugin!.initialize(
    const InitializationSettings(android: android),
    onDidReceiveNotificationResponse: (response) {
      final actionId = response.actionId;
      if (actionId != null && actionId.isNotEmpty && onAction != null) {
        onAction(actionId, response.payload);
        return;
      }
      onTap?.call(response.payload);
    },
  );
  final androidPlugin = _plugin!
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'privet_messages',
      'Messages',
      description: 'New chat messages',
      importance: Importance.high,
    ),
  );
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'privet_calls',
      'Calls',
      description: 'Incoming calls',
      importance: Importance.max,
      playSound: true,
    ),
  );
  _pluginReady = true;
}

/// Build the exact notification payload string used for a call ring, so a
/// later accept/decline can cancel/update the same notification.
String encodeCallNotificationPayload(Map<String, dynamic> data) {
  String v(String key) => data[key]?.toString() ?? '';
  final callId = v('callId');
  return encodeNotificationPayload({
    'type': 'call.incoming',
    if (v('conversationId').isNotEmpty) 'conversationId': v('conversationId'),
    if (callId.isNotEmpty) 'callId': callId,
    if (v('mode').isNotEmpty) 'mode': v('mode'),
    if (v('fromUserId').isNotEmpty) 'fromUserId': v('fromUserId'),
    if (v('callerDisplayName').isNotEmpty)
      'callerDisplayName': v('callerDisplayName'),
    if (v('callerHandle').isNotEmpty) 'callerHandle': v('callerHandle'),
    if (v('callerAvatarHue').isNotEmpty) 'callerAvatarHue': v('callerAvatarHue'),
  });
}

/// If this app process was cold-started by tapping (or full-screen-launching)
/// one of our notifications, return that notification's response so the caller
/// can replay it once the UI is ready. Null when there is no launch to replay.
Future<NotificationResponse?> takeLaunchNotificationResponse() async {
  try {
    final plugin = _plugin ?? FlutterLocalNotificationsPlugin();
    final details = await plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp ?? false) {
      return details?.notificationResponse;
    }
  } catch (e, st) {
    debugPrint('[privet] launch notification read failed: $e\n$st');
  }
  return null;
}

/// Cancel every posted notification whose Android tag equals [tag] — used to
/// remove the OS-posted FCM display notification for a call before the app's
/// own full-screen Accept/Decline notification replaces it.
Future<void> cancelMobileNotificationsByTag(String tag) async {
  if (tag.isEmpty) return;
  try {
    await _fsiChannel.invokeMethod<void>(
      'cancelNotificationsByTag',
      {'tag': tag},
    );
  } catch (e, st) {
    debugPrint('[privet] cancel-notifications-by-tag failed: $e\n$st');
  }
}

Future<void> cancelMobileNotification(String tag) async {
  final plugin = _plugin;
  if (plugin == null || tag.isEmpty) return;
  await plugin.cancel(tag.hashCode & 0x7fffffff);
}

Future<void> showMobileNotificationFromRemoteMessage(
  RemoteMessage message, {
  bool force = false,
}) async {
  final data = message.data;
  final type = data['type'] ?? '';
  final isCall = type == 'call.incoming';
  final conversationId = data['conversationId'] ?? '';
  final callId = data['callId'] ?? '';
  final dedupeKey = isCall
      ? 'call:$callId'
      : 'msg:${data['messageId'] ?? conversationId}';

  if (!force && shouldSuppressMobileNotification(dedupeKey)) return;

  final notification = message.notification;
  final title = notification?.title ??
      data['title'] ??
      (isCall ? 'Incoming call' : 'Privet');
  final body = notification?.body ??
      data['body'] ??
      (isCall ? 'Tap to answer' : 'New message');

  final payload = isCall
      ? encodeCallNotificationPayload(data)
      : encodeNotificationPayload({
          'type': type,
          if (conversationId.isNotEmpty) 'conversationId': conversationId,
          if (callId.isNotEmpty) 'callId': callId,
        });

  await showMobileNotification(
    title: title,
    body: body,
    isCall: isCall,
    tag: isCall ? 'call:$callId' : 'chat:$conversationId',
    payload: payload,
  );
}

Future<void> showMobileNotification({
  required String title,
  required String body,
  String? payload,
  bool isCall = false,
  String? tag,
}) async {
  if (!_pluginReady) {
    await initMobileNotificationPlugin();
  }
  final plugin = _plugin;
  if (plugin == null) return;

  final androidPlugin = plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  if (androidPlugin != null) {
    final granted = await androidPlugin.requestNotificationsPermission();
    if (granted != true) {
      debugPrint('[privet] notification permission denied');
      return;
    }
  }

  final id = tag != null && tag.isNotEmpty
      ? tag.hashCode
      : DateTime.now().millisecondsSinceEpoch;
  await plugin.show(
    id & 0x7fffffff,
    title,
    body.isEmpty ? ' ' : body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        isCall ? 'privet_calls' : 'privet_messages',
        isCall ? 'Calls' : 'Messages',
        importance: isCall ? Importance.max : Importance.high,
        priority: isCall ? Priority.max : Priority.high,
        category: isCall
            ? AndroidNotificationCategory.call
            : AndroidNotificationCategory.message,
        fullScreenIntent: isCall,
        visibility: NotificationVisibility.public,
        autoCancel: !isCall,
        tag: tag,
        // Full-color logo shown in the shade / heads-up / lock screen.
        largeIcon: const DrawableResourceAndroidBitmap('ic_privet_logo'),
        timeoutAfter: isCall ? 60000 : null,
        actions: isCall
            ? const [
                AndroidNotificationAction(
                  'answer',
                  'Answer',
                  showsUserInterface: true,
                ),
                AndroidNotificationAction(
                  'decline',
                  'Decline',
                  showsUserInterface: true,
                ),
              ]
            : null,
      ),
    ),
    payload: payload,
  );
}
