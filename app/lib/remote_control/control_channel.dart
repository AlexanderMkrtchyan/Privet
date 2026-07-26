import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api/realtime.dart';
import '../util/remote_input.dart';
import 'protocol.dart';

typedef RemoteControlNotify = void Function();

/// Owns the WebRTC data channel + host injection for one [CallSession].
class RemoteControlChannel {
  RemoteControlChannel({
    required this.rt,
    required this.callId,
    required this.selfId,
    required this.peerId,
    required this.isCaller,
    required this.notify,
    required this.isSharingLocally,
    required this.peerSharingScreen,
  });

  final RealtimeClient rt;
  final String callId;
  final String selfId;
  final String peerId;
  final bool isCaller;
  final RemoteControlNotify notify;
  final bool Function() isSharingLocally;
  final bool Function() peerSharingScreen;

  final state = RemoteControlSessionState();

  RTCDataChannel? _channel;
  Timer? _heartbeat;
  Timer? _heartbeatWatch;
  RemoteInputCapability _capability = RemoteInputCapability.unsupported;
  bool _incomingRequest = false;
  String? _error;
  double? _pendingMoveX;
  double? _pendingMoveY;
  int _pendingMoveButtons = 0;
  DateTime? _lastMoveSent;
  Timer? _moveFlushTimer;
  static const _moveMinInterval = Duration(milliseconds: 33); // ~30Hz

  RemoteInputCapability get capability => _capability;
  bool get incomingRequest => _incomingRequest;
  String? get error => _error;

  bool get canRequestControl =>
      state.auth == RemoteControlAuth.idle ||
      state.auth == RemoteControlAuth.denied;

  /// Controller may ask when the peer is sharing and we are not.
  bool get canActAsController =>
      peerSharingScreen() && !isSharingLocally();

  /// Host may grant only while sharing from a capable native desktop.
  bool get canActAsHost =>
      isSharingLocally() && _capability.canInject;

  Future<void> attach(RTCPeerConnection pc) async {
    await refreshCapability();
    pc.onDataChannel = (channel) {
      if (channel.label == 'privet-control') {
        _bindChannel(channel);
      }
    };
    if (isCaller) {
      final init = RTCDataChannelInit()
        ..ordered = true
        ..protocol = 'privet-control';
      final channel = await pc.createDataChannel('privet-control', init);
      _bindChannel(channel);
    }
  }

  /// Re-probe OS inject capability (call before advertising share / granting).
  Future<RemoteInputCapability> refreshCapability() async {
    _capability = await RemoteInput.probe();
    return _capability;
  }

  void _bindChannel(RTCDataChannel channel) {
    _channel = channel;
    channel.onMessage = (msg) {
      if (msg.isBinary) return;
      unawaited(_onChannelMessage(msg.text));
    };
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelClosed) {
        _onChannelClosed();
      }
    };
  }

  Future<void> requestControl() async {
    _error = null;
    if (!canActAsController) {
      _error = 'Wait until the other person is sharing their screen.';
      notify();
      return;
    }
    if (!canRequestControl && state.auth != RemoteControlAuth.requested) {
      return;
    }
    state.markRequested(asController: true);
    rt.requestControl(callId: callId, toUserId: peerId);
    notify();
  }

  Future<void> rejectRequest(String message) async {
    _error = message;
    _incomingRequest = false;
    if (state.auth == RemoteControlAuth.requested) {
      state.markDenied();
    }
    notify();
  }

  Future<void> grantControl() async {
    _error = null;
    await refreshCapability();
    if (!canActAsHost) {
      final reason = _capability.canInject
          ? 'Start screen sharing before granting control.'
          : (_capability.detail.isNotEmpty
              ? _capability.detail
              : 'This device cannot be controlled remotely.');
      _error = reason;
      _incomingRequest = false;
      // Tell the controller immediately — do not leave them on "Waiting…".
      state.markDenied();
      rt.denyControl(callId: callId, toUserId: peerId, reason: reason);
      notify();
      return;
    }
    _incomingRequest = false;
    state.markGranted(asController: false);
    try {
      await RemoteInput.ensureReady();
    } catch (e) {
      final reason = 'Could not enable OS input: $e';
      _error = reason;
      state.markDenied();
      rt.denyControl(callId: callId, toUserId: peerId, reason: reason);
      notify();
      return;
    }
    await _publishGeometry();
    rt.grantControl(callId: callId, toUserId: peerId);
    _startHostWatch();
    notify();
  }

  void denyControl({String reason = 'Remote control was denied.'}) {
    _incomingRequest = false;
    state.markDenied();
    rt.denyControl(callId: callId, toUserId: peerId, reason: reason);
    notify();
  }

  Future<void> revokeControl({bool notifyPeer = true}) async {
    final wasGranted = state.isGranted;
    final wasHost = state.role == RemoteControlRole.host;
    final wasController = state.role == RemoteControlRole.controller;
    _incomingRequest = false;
    _stopTimers();
    if (wasHost) {
      try {
        await RemoteInput.releaseAll();
      } catch (_) {}
    }
    if (wasController) {
      _sendRaw(RemoteControlProtocol.releaseAll());
    }
    state.markRevoked();
    if (notifyPeer && wasGranted) {
      rt.revokeControl(callId: callId, toUserId: peerId);
    }
    notify();
  }

  void onPeerRequest() {
    // Only the screen-sharing host should see the consent dialog.
    if (!isSharingLocally()) return;
    _incomingRequest = true;
    state.markRequested(asController: false);
    notify();
  }

  void onPeerGrant() {
    state.markGranted(asController: true);
    _startControllerHeartbeat();
    notify();
  }

  void onPeerDeny([String? reason]) {
    final wasControllerSide =
        state.role == RemoteControlRole.controller ||
        state.auth == RemoteControlAuth.requested;
    state.markDenied();
    if (wasControllerSide) {
      _error = remoteControlDeniedReason(reason);
    }
    _stopTimers();
    notify();
  }

  Future<void> onPeerRevoke() async {
    await revokeControl(notifyPeer: false);
  }

  /// Called when local screen share stops.
  Future<void> onLocalShareStopped() async {
    if (state.role == RemoteControlRole.host || _incomingRequest) {
      await revokeControl();
    }
  }

  /// Called when peer stops sharing.
  Future<void> onRemoteShareStopped() async {
    if (state.role == RemoteControlRole.controller ||
        state.auth == RemoteControlAuth.requested) {
      await revokeControl();
    }
  }

  Future<void> sendPointerMove(double x, double y, {int buttons = 0}) async {
    if (!state.isController) return;
    _pendingMoveX = x;
    _pendingMoveY = y;
    _pendingMoveButtons = buttons;
    final now = DateTime.now();
    final last = _lastMoveSent;
    if (last == null || now.difference(last) >= _moveMinInterval) {
      _flushPendingMove();
      return;
    }
    _moveFlushTimer ??= Timer(_moveMinInterval - now.difference(last), () {
      _moveFlushTimer = null;
      _flushPendingMove();
    });
  }

  void _flushPendingMove() {
    final x = _pendingMoveX;
    final y = _pendingMoveY;
    if (x == null || y == null) return;
    _pendingMoveX = null;
    _pendingMoveY = null;
    _lastMoveSent = DateTime.now();
    _sendRaw(RemoteControlProtocol.pointerMove(
      x: x,
      y: y,
      buttons: _pendingMoveButtons,
    ));
  }

  Future<void> sendPointerButton({
    required double x,
    required double y,
    required int button,
    required bool down,
    int buttons = 0,
  }) async {
    if (!state.isController) return;
    _sendRaw(RemoteControlProtocol.pointerButton(
      x: x,
      y: y,
      button: button,
      down: down,
      buttons: buttons,
    ));
  }

  Future<void> sendWheel({
    required double x,
    required double y,
    required double dx,
    required double dy,
  }) async {
    if (!state.isController) return;
    _sendRaw(RemoteControlProtocol.wheel(x: x, y: y, dx: dx, dy: dy));
  }

  Future<void> sendKey({
    required String code,
    required bool down,
    int mods = 0,
    String? key,
  }) async {
    if (!state.isController) return;
    // Never inject OS-reserved chords from the controller wire protocol
    // on the host; still avoid sending the most dangerous combos.
    if (_isBlockedChord(code: code, mods: mods)) return;
    _sendRaw(RemoteControlProtocol.keyEvent(
      code: code,
      down: down,
      mods: mods,
      key: key,
    ));
  }

  Future<void> sendFocusLost() async {
    if (!state.isController) return;
    _sendRaw(RemoteControlProtocol.releaseAll());
  }

  Future<void> updateLocalGeometry(int width, int height) async {
    if (width <= 0 || height <= 0) return;
    state.displayWidth = width;
    state.displayHeight = height;
    if (state.isHost) {
      await _publishGeometry();
    }
  }

  Future<void> _publishGeometry() async {
    if (!state.hasGeometry) {
      // Fallback primary display size is better than nothing.
      state.displayWidth = state.displayWidth <= 0 ? 1920 : state.displayWidth;
      state.displayHeight =
          state.displayHeight <= 0 ? 1080 : state.displayHeight;
    }
    _sendRaw(RemoteControlProtocol.geometry(
      width: state.displayWidth,
      height: state.displayHeight,
    ));
  }

  void _sendRaw(String payload) {
    final ch = _channel;
    if (ch == null) return;
    if (ch.state != RTCDataChannelState.RTCDataChannelOpen) return;
    if (payload.length > kRemoteControlMaxMessageBytes) return;
    try {
      ch.send(RTCDataChannelMessage(payload));
    } catch (e) {
      debugPrint('remote control send failed: $e');
    }
  }

  Future<void> _onChannelMessage(String raw) async {
    final msg = RemoteControlProtocol.decode(raw);
    if (msg == null) return;
    final t = msg['t'] as String;

    if (t == 'hb') {
      state.noteHeartbeat();
      return;
    }
    if (t == 'geom') {
      final w = msg['w'];
      final h = msg['h'];
      if (w is int && h is int && w > 0 && h > 0) {
        state.displayWidth = w;
        state.displayHeight = h;
        notify();
      }
      return;
    }
    if (t == 'release') {
      if (state.isHost) {
        try {
          await RemoteInput.releaseAll();
        } catch (_) {}
      }
      return;
    }

    // Input events are host-only and require a live grant + screen share.
    if (!state.isHost || !isSharingLocally()) return;
    if (!state.acceptHostEvent(DateTime.now())) return;

    final w = state.displayWidth;
    final h = state.displayHeight;
    if (w <= 0 || h <= 0) return;

    try {
      switch (t) {
        case 'ptr':
          final x = (msg['x'] as num?)?.toDouble();
          final y = (msg['y'] as num?)?.toDouble();
          if (x == null || y == null) return;
          final a = msg['a'] as String? ?? 'move';
          if (a == 'move') {
            await RemoteInput.pointerMove(
              x: x,
              y: y,
              displayWidth: w,
              displayHeight: h,
            );
          } else if (a == 'down' || a == 'up') {
            final btn = msg['btn'] as int? ?? RemotePointerButton.primary;
            await RemoteInput.pointerButton(
              x: x,
              y: y,
              displayWidth: w,
              displayHeight: h,
              button: btn,
              down: a == 'down',
            );
          }
        case 'wheel':
          final x = (msg['x'] as num?)?.toDouble();
          final y = (msg['y'] as num?)?.toDouble();
          final dx = (msg['dx'] as num?)?.toDouble() ?? 0;
          final dy = (msg['dy'] as num?)?.toDouble() ?? 0;
          if (x == null || y == null) return;
          await RemoteInput.wheel(
            x: x,
            y: y,
            displayWidth: w,
            displayHeight: h,
            dx: dx,
            dy: dy,
          );
        case 'key':
          final code = msg['code'] as String?;
          final down = msg['down'] as bool?;
          if (code == null || down == null) return;
          final mods = msg['mods'] as int? ?? 0;
          if (_isBlockedChord(code: code, mods: mods)) return;
          await RemoteInput.keyEvent(
            code: code,
            down: down,
            mods: mods,
            key: msg['key'] as String?,
          );
      }
    } catch (e) {
      debugPrint('remote input inject failed: $e');
    }
  }

  void _startControllerHeartbeat() {
    _stopTimers();
    _heartbeat = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!state.isController) return;
      _sendRaw(RemoteControlProtocol.heartbeat());
    });
  }

  void _startHostWatch() {
    _stopTimers();
    state.noteHeartbeat();
    _heartbeatWatch = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!state.isHost) return;
      if (state.heartbeatExpired()) {
        await revokeControl();
      }
    });
  }

  void _stopTimers() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _heartbeatWatch?.cancel();
    _heartbeatWatch = null;
    _moveFlushTimer?.cancel();
    _moveFlushTimer = null;
  }

  void _onChannelClosed() {
    unawaited(revokeControl(notifyPeer: false));
  }

  static bool _isBlockedChord({required String code, required int mods}) {
    final ctrl = (mods & RemoteKeyMods.ctrl) != 0;
    final alt = (mods & RemoteKeyMods.alt) != 0;
    final meta = (mods & RemoteKeyMods.meta) != 0;
    // Block OS-level secure attention / session shortcuts.
    if (code == 'Escape' && ctrl && alt) return true;
    if (code == 'Delete' && ctrl && alt) return true;
    if (meta && (code == 'KeyL' || code == 'KeyQ' || code == 'F4')) return true;
    if (code == 'MetaLeft' || code == 'MetaRight' || code == 'OSLeft' || code == 'OSRight') {
      return true;
    }
    return false;
  }

  Future<void> dispose() async {
    _stopTimers();
    _incomingRequest = false;
    if (state.role == RemoteControlRole.host) {
      try {
        await RemoteInput.releaseAll();
      } catch (_) {}
    }
    state.reset();
    try {
      await _channel?.close();
    } catch (_) {}
    _channel = null;
  }
}
