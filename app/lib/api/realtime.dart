import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

typedef WsHandler = void Function(Map<String, dynamic> event);

class RealtimeClient {
  RealtimeClient({required this.url});

  final String url;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _handlers = <WsHandler>[];
  bool _authSent = false;
  String? _authToken;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _manualDisconnect = false;

  /// Fired after an automatic reconnect succeeds (e.g. app resume / network flap).
  void Function()? onReconnected;

  void addHandler(WsHandler handler) => _handlers.add(handler);
  void removeHandler(WsHandler handler) => _handlers.remove(handler);

  Future<void> connect(String token) async {
    _manualDisconnect = false;
    _authToken = token;
    await _openConnection(token);
  }

  Future<void> _openConnection(String token) async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = WebSocketChannel.connect(Uri.parse(url));
    _authSent = false;
    _sub = _channel!.stream.listen(
      (raw) {
        final data = jsonDecode(raw as String) as Map<String, dynamic>;
        for (final h in List<WsHandler>.from(_handlers)) {
          h(data);
        }
      },
      onDone: _onConnectionLost,
      onError: (_) => _onConnectionLost(),
    );
    send({'type': 'auth', 'token': token});
    _authSent = true;
    _reconnectAttempt = 0;
  }

  void _onConnectionLost() {
    if (_manualDisconnect || _authToken == null) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _authToken == null) return;
    _reconnectTimer?.cancel();
    final delaySec = math.min(30, 1 << _reconnectAttempt);
    _reconnectAttempt = math.min(_reconnectAttempt + 1, 5);
    _reconnectTimer = Timer(Duration(seconds: delaySec), () async {
      if (_manualDisconnect || _authToken == null) return;
      try {
        await _openConnection(_authToken!);
        onReconnected?.call();
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  /// Re-open the socket if it dropped (foreground resume, network flap).
  Future<void> ensureConnected(String token) async {
    _authToken = token;
    if (isConnected) return;
    await connect(token);
  }

  void send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  void sendMessage({
    required String conversationId,
    required String body,
    String kind = 'text',
    String? clientId,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    int? fileSize,
    String? replyToId,
    String? replyQuote,
    List<Map<String, dynamic>>? attachments,
    String? forwardFromId,
  }) {
    send({
      'type': 'message.send',
      'conversationId': conversationId,
      'body': body,
      'kind': kind,
      'clientId': clientId,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (mimeType != null) 'mimeType': mimeType,
      if (fileName != null) 'fileName': fileName,
      if (fileSize != null) 'fileSize': fileSize,
      if (replyToId != null) 'replyToId': replyToId,
      if (replyQuote != null && replyQuote.isNotEmpty) 'replyQuote': replyQuote,
      if (attachments != null) 'attachments': attachments,
      if (forwardFromId != null) 'forwardFromId': forwardFromId,
    });
  }

  void toggleReaction({required String messageId, required String emoji}) {
    send({
      'type': 'reaction.toggle',
      'messageId': messageId,
      'emoji': emoji,
    });
  }

  void editMessage({required String messageId, required String body}) {
    send({
      'type': 'message.edit',
      'messageId': messageId,
      'body': body,
    });
  }

  void deleteMessage({required String messageId}) {
    send({'type': 'message.delete', 'messageId': messageId});
  }

  void typing(String conversationId) {
    send({'type': 'typing', 'conversationId': conversationId});
  }

  void markRead({
    required String conversationId,
    String? messageId,
    bool focused = false,
  }) {
    send({
      'type': 'conversation.read',
      'conversationId': conversationId,
      if (messageId != null) 'messageId': messageId,
      'focused': focused,
    });
  }

  void inviteCall({
    required String conversationId,
    required String toUserId,
    required String mode,
  }) {
    send({
      'type': 'call.invite',
      'conversationId': conversationId,
      'toUserId': toUserId,
      'mode': mode,
    });
  }

  void acceptCall(String callId) => send({'type': 'call.accept', 'callId': callId});

  void rejectCall(String callId) => send({'type': 'call.reject', 'callId': callId});

  void hangupCall(String callId, {String? toUserId}) => send({
        'type': 'call.hangup',
        'callId': callId,
        if (toUserId != null) 'toUserId': toUserId,
      });

  void sendOffer({
    required String callId,
    required String toUserId,
    required Map<String, dynamic> sdp,
  }) {
    send({
      'type': 'call.offer',
      'callId': callId,
      'toUserId': toUserId,
      'sdp': sdp,
    });
  }

  void sendAnswer({
    required String callId,
    required String toUserId,
    required Map<String, dynamic> sdp,
  }) {
    send({
      'type': 'call.answer',
      'callId': callId,
      'toUserId': toUserId,
      'sdp': sdp,
    });
  }

  void sendIce({
    required String callId,
    required String toUserId,
    required Map<String, dynamic> candidate,
  }) {
    send({
      'type': 'call.ice',
      'callId': callId,
      'toUserId': toUserId,
      'candidate': candidate,
    });
  }

  /// Explicit signal — WebRTC mute/ended often leaves a frozen last frame.
  void sendShareStopped({
    required String callId,
    required String toUserId,
  }) {
    send({
      'type': 'call.share_stopped',
      'callId': callId,
      'toUserId': toUserId,
    });
  }

  void sendShareStarted({
    required String callId,
    required String toUserId,
    bool controllable = false,
    String controlPlatform = '',
    String controlBackend = '',
    String controlDetail = '',
  }) {
    send({
      'type': 'call.share_started',
      'callId': callId,
      'toUserId': toUserId,
      'controllable': controllable,
      if (controlPlatform.isNotEmpty) 'controlPlatform': controlPlatform,
      if (controlBackend.isNotEmpty) 'controlBackend': controlBackend,
      if (controlDetail.isNotEmpty) 'controlDetail': controlDetail,
    });
  }

  void requestControl({
    required String callId,
    required String toUserId,
  }) {
    send({
      'type': 'call.control_request',
      'callId': callId,
      'toUserId': toUserId,
    });
  }

  void grantControl({
    required String callId,
    required String toUserId,
  }) {
    send({
      'type': 'call.control_grant',
      'callId': callId,
      'toUserId': toUserId,
    });
  }

  void denyControl({
    required String callId,
    required String toUserId,
    String? reason,
  }) {
    final trimmed = reason?.trim();
    send({
      'type': 'call.control_deny',
      'callId': callId,
      'toUserId': toUserId,
      if (trimmed != null && trimmed.isNotEmpty) 'reason': trimmed,
    });
  }

  void revokeControl({
    required String callId,
    required String toUserId,
  }) {
    send({
      'type': 'call.control_revoke',
      'callId': callId,
      'toUserId': toUserId,
    });
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _authToken = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _authSent = false;
  }

  bool get isConnected => _channel != null && _authSent;
}
