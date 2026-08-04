import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'mobile_app_lifecycle.dart';
import 'mobile_push_io.dart';

FlutterLocalNotificationsPlugin? _plugin;
bool _pluginReady = false;

Future<void> initMobileNotificationPlugin({
  void Function(String? payload)? onTap,
}) async {
  if (_pluginReady && onTap == null) return;
  _plugin ??= FlutterLocalNotificationsPlugin();
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _plugin!.initialize(
    const InitializationSettings(android: android),
    onDidReceiveNotificationResponse: (response) {
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

  await showMobileNotification(
    title: title,
    body: body,
    isCall: isCall,
    payload: encodeNotificationPayload({
      'type': type,
      if (conversationId.isNotEmpty) 'conversationId': conversationId,
      if (callId.isNotEmpty) 'callId': callId,
    }),
  );
}

Future<void> showMobileNotification({
  required String title,
  required String body,
  String? payload,
  bool isCall = false,
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

  final id = payload?.hashCode ?? DateTime.now().millisecondsSinceEpoch;
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
        ongoing: isCall,
        autoCancel: !isCall,
      ),
    ),
    payload: payload,
  );
}
