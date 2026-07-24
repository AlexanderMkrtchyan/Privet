import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

typedef WsHandler = void Function(Map<String, dynamic> event);

class RealtimeClient {
  RealtimeClient({required this.url});

  final String url;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _handlers = <WsHandler>[];
  bool _authSent = false;

  void addHandler(WsHandler handler) => _handlers.add(handler);
  void removeHandler(WsHandler handler) => _handlers.remove(handler);

  Future<void> connect(String token) async {
    await disconnect();
    _channel = WebSocketChannel.connect(Uri.parse(url));
    _authSent = false;
    _sub = _channel!.stream.listen(
      (raw) {
        final data = jsonDecode(raw as String) as Map<String, dynamic>;
        for (final h in List<WsHandler>.from(_handlers)) {
          h(data);
        }
      },
      onDone: () {},
      onError: (_) {},
    );
    send({'type': 'auth', 'token': token});
    _authSent = true;
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
    send({
      'type': 'message.delete',
      'messageId': messageId,
    });
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

  void typing(String conversationId) {
    send({'type': 'typing', 'conversationId': conversationId});
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
  }) {
    send({
      'type': 'call.share_started',
      'callId': callId,
      'toUserId': toUserId,
    });
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    _authSent = false;
  }

  bool get isConnected => _channel != null && _authSent;
}
