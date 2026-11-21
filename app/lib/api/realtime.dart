import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_channel_stub.dart'
    if (dart.library.io) 'realtime_channel_io.dart';

typedef WsHandler = void Function(Map<String, dynamic> event);

class RealtimeClient {
  RealtimeClient({
    required this.url,
    WebSocketChannel Function(Uri)? connector,
    this.heartbeatInterval = const Duration(seconds: 20),
    this.staleAfter = const Duration(seconds: 65),
  }) : _connect = connector ?? connectRealtimeChannel;

  final String url;
  final WebSocketChannel Function(Uri) _connect;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _handlers = <WsHandler>[];
  bool _authSent = false;
  bool _authAcked = false;
  String? _authToken;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _manualDisconnect = false;
  /// True once the server has confirmed at least one socket (`auth.ok`).
  bool _everConnected = false;

  /// App-level heartbeat. Idle NAT/proxy/mobile-network paths drop a WebSocket
  /// without a FIN, so neither [onDone] nor [onError] fires and the client keeps
  /// thinking it is connected while the server's sends vanish into a half-open
  /// socket. Android also freezes the isolate in the background, so the OS-level
  /// `pingInterval` cannot run there; pinging on a timer and treating silence as
  /// death makes the client reconnect (and pull the inbox) instead of going dark
  /// until the user kills the app.
  Timer? _heartbeatTimer;
  DateTime? _lastInboundAt;
  bool _forceReconnecting = false;
  /// How often the client proves the socket still answers.
  final Duration heartbeatInterval;

  /// Silence longer than this means the socket is a half-open corpse.
  final Duration staleAfter;

  /// Fired after an automatic reconnect succeeds (server answered `auth.ok`).
  void Function()? onReconnected;

  /// Bumped on every connection attempt. A listener from an older socket
  /// compares its generation and ignores itself, so a late `onDone` from a
  /// superseded socket can never tear down the socket that replaced it.
  int _generation = 0;
  /// Set once the close of the current generation has been handled, so a socket
  /// that fires both `onError` and `onDone` only schedules one reconnect.
  bool _lostHandled = false;
  /// Serializes connection attempts. Rapid pause/resume cycles (the mobile
  /// lifecycle can fire `resumed` several times per second) must never open two
  /// sockets at once: the interleaved awaits used to leave `_channel` pointing at
  /// one socket while `_sub` listened to another.
  Future<void> _openQueue = Future<void>.value();
  DateTime? _lastOpenedAt;

  void addHandler(WsHandler handler) => _handlers.add(handler);
  void removeHandler(WsHandler handler) => _handlers.remove(handler);

  Future<void> connect(String token) async {
    _manualDisconnect = false;
    _authToken = token;
    // Fire and forget: bootstrap/login must not wait for a handshake a flaky
    // network can stall. The connection queue keeps attempts ordered and the
    // auth frame is buffered by the channel until the socket is up.
    unawaited(_queueOpen(token));
  }

  /// Re-open the socket if it dropped (foreground resume, network flap).
  ///
  /// [force] closes a still-open socket first — needed after Android/iOS
  /// freeze the isolate long enough that [isConnected] is a lie (half-open
  /// NAT drop, no FIN, pingInterval never ran while paused).
  Future<void> ensureConnected(String token, {bool force = false}) async {
    _authToken = token;
    _manualDisconnect = false;
    if (!force && isConnected) return;
    // Only resume storms are coalesced: an internal heartbeat reconnect means
    // the socket is provably dead and must be replaced even if it is new.
    await _queueOpen(token, force: force, coalesceRecent: true);
  }

  bool get isConnected => _channel != null && _authSent;

  bool get _openedRecently {
    final at = _lastOpenedAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 2);
  }

  Future<void> _queueOpen(
    String token, {
    bool force = true,
    bool coalesceRecent = false,
  }) {
    final next = _openQueue.then((_) {
      if (_manualDisconnect || _authToken != token) return Future<void>.value();
      if (!force && isConnected) return Future<void>.value();
      // A force-reconnect that lands right after another open (resume storms,
      // notification taps + lifecycle events together) must not churn a socket
      // that is less than two seconds old and therefore cannot be stale yet.
      if (coalesceRecent && force && isConnected && _openedRecently) {
        return Future<void>.value();
      }
      return _openConnection(token);
    });
    _openQueue = next.catchError((Object _) {});
    return _openQueue;
  }

  Future<void> _openConnection(String token) async {
    final gen = ++_generation;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lostHandled = false;
    final oldSub = _sub;
    final oldChannel = _channel;
    _sub = null;
    _channel = null;
    _authSent = false;
    _authAcked = false;
    _lastInboundAt = null;
    // Never await a half-open socket's close handshake: a dead peer can keep
    // `close()` (and sometimes `cancel()`) pending forever, which would block
    // the very reconnect that is supposed to recover the app.
    unawaited(_disposeSocket(oldSub, oldChannel));
    // A newer attempt (or a logout) superseded us while tearing the old
    // socket down — never open a socket the caller no longer wants.
    if (gen != _generation || _manualDisconnect || _authToken != token) return;
    try {
      final channel = _connect(Uri.parse(url));
      _channel = channel;
      final sub = channel.stream.listen(
        (raw) => _onRaw(gen, raw),
        onDone: () => _onConnectionLost(gen),
        onError: (Object _) => _onConnectionLost(gen),
        cancelOnError: true,
      );
      _sub = sub;
      // Connection failures (no network, refused, TLS) surface on `ready`, and
      // only there when the failure happens before any frame. Without awaiting
      // it the error was unhandled and the caller believed it had a socket.
      // Bound it: a TCP connection that never upgrades must not hang a resume.
      await channel.ready.timeout(const Duration(seconds: 10));
      if (gen != _generation || _manualDisconnect || _authToken != token) {
        // Superseded mid-handshake — drop this socket, not the replacement.
        unawaited(_disposeSocket(sub, channel));
        return;
      }
      // Any inbound byte proves the socket is alive end to end.
      _lastOpenedAt = DateTime.now();
      _lastInboundAt = _lastOpenedAt;
      channel.sink.add(jsonEncode({'type': 'auth', 'token': token}));
      _authSent = true;
      _reconnectAttempt = 0;
      _startHeartbeat();
    } catch (_) {
      // The socket can fail synchronously (no network while resuming). This
      // used to propagate out of `ensureConnected` and abort the whole resume
      // refresh, leaving the app silently stale until it was restarted.
      if (gen != _generation || _lostHandled) return;
      _lostHandled = true;
      final sub = _sub;
      final channel = _channel;
      _sub = null;
      _channel = null;
      _authSent = false;
      _authAcked = false;
      _lastInboundAt = null;
      unawaited(_disposeSocket(sub, channel));
      _scheduleReconnect();
    }
  }

  static Future<void> _disposeSocket(
    StreamSubscription? sub,
    WebSocketChannel? channel,
  ) async {
    try {
      await sub?.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await channel?.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _onRaw(int gen, Object? raw) {
    if (gen != _generation) return;
    _lastInboundAt = DateTime.now();
    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (data['type'] == 'auth.ok' && !_authAcked) {
      // Only the server's ack proves this socket is bound; an `onReconnected`
      // fired before it would resync over a socket that is already dead.
      _authAcked = true;
      if (_everConnected) onReconnected?.call();
      _everConnected = true;
    }
    for (final h in List<WsHandler>.from(_handlers)) {
      h(data);
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (_manualDisconnect || _authToken == null || !_authSent) return;
      final last = _lastInboundAt;
      if (last == null || DateTime.now().difference(last) > staleAfter) {
        _forceReconnect();
        return;
      }
      send({'type': 'ping'});
    });
  }

  /// Close a socket that stopped answering, then reopen + resync immediately.
  void _forceReconnect() {
    if (_manualDisconnect || _authToken == null || _forceReconnecting) return;
    _forceReconnecting = true;
    final token = _authToken!;
    unawaited(() async {
      try {
        await _queueOpen(token);
      } finally {
        _forceReconnecting = false;
      }
    }());
  }

  void _onConnectionLost(int gen) {
    // A late close from a socket we already replaced must not kill the new one.
    if (gen != _generation || _lostHandled) return;
    _lostHandled = true;
    // Stop reporting a connected socket the moment the stream ends; otherwise
    // `ensureConnected()` returns early and the app waits out the reconnect
    // backoff with a socket that is already gone.
    _channel = null;
    _sub = null;
    _authSent = false;
    _authAcked = false;
    _lastInboundAt = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_manualDisconnect || _authToken == null) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _authToken == null) return;
    _reconnectTimer?.cancel();
    final delaySec = math.min(30, 1 << _reconnectAttempt);
    _reconnectAttempt = math.min(_reconnectAttempt + 1, 5);
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (_manualDisconnect || _authToken == null) return;
      final token = _authToken!;
      unawaited(_queueOpen(token));
    });
  }

  void send(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(payload));
    } catch (_) {
      // Sink already closed — the connection-lost path reconnects.
    }
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
    _generation++;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _forceReconnecting = false;
    _lostHandled = true;
    _lastInboundAt = null;
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    _authSent = false;
    _authAcked = false;
    await _disposeSocket(sub, channel);
  }
}
