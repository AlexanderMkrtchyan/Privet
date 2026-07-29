import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api/realtime.dart';
import '../util/app_clipboard.dart';
import '../util/remote_input.dart';
import 'protocol.dart';

typedef RemoteControlNotify = void Function();
typedef RemoteControlQualityHandler = Future<void> Function(
  RemoteControlQuality mode,
);
typedef RemoteControlSwitchDisplayHandler = Future<void> Function(String id);
typedef RemoteControlListDisplaysHandler = Future<List<RemoteDisplayInfo>>
    Function();

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
    this.onQualityRequested,
    this.onSwitchDisplay,
    this.listDisplays,
  });

  final RealtimeClient rt;
  final String callId;
  final String selfId;
  final String peerId;
  final bool isCaller;
  final RemoteControlNotify notify;
  final bool Function() isSharingLocally;
  final bool Function() peerSharingScreen;
  RemoteControlQualityHandler? onQualityRequested;
  RemoteControlSwitchDisplayHandler? onSwitchDisplay;
  RemoteControlListDisplaysHandler? listDisplays;

  final state = RemoteControlSessionState();

  RTCDataChannel? _channel;
  Timer? _heartbeat;
  Timer? _heartbeatWatch;
  Timer? _clipboardPoll;
  RemoteInputCapability _capability = RemoteInputCapability.unsupported;
  bool _incomingRequest = false;
  bool _consentDialogOpen = false;
  String? _error;
  double? _pendingMoveX;
  double? _pendingMoveY;
  int _pendingMoveButtons = 0;
  DateTime? _lastMoveSent;
  Timer? _moveFlushTimer;
  static const _moveMinInterval = Duration(milliseconds: 33); // ~30Hz

  RemoteControlQuality quality = RemoteControlQuality.balanced;
  List<RemoteDisplayInfo> peerDisplays = const [];
  String? activeDisplayId;
  String? lastClipboardFromPeer;
  bool hostInputLocked = false;
  String? _lastClipSent;
  String? _lastClipApplied;

  RemoteInputCapability get capability => _capability;
  bool get incomingRequest => _incomingRequest;
  bool get consentDialogOpen => _consentDialogOpen;
  String? get error => _error;

  void setConsentDialogOpen(bool open) {
    _consentDialogOpen = open;
  }

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
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        // Grant may have happened before the channel was open (control invite).
        if (state.isHost) {
          unawaited(_publishGeometry());
          unawaited(_publishDisplays());
        }
        if (state.isController) {
          _sendRaw(RemoteControlProtocol.heartbeat());
          _sendRaw(RemoteControlProtocol.quality(quality));
        }
      }
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
    if (state.isGranted ||
        (state.auth == RemoteControlAuth.requested &&
            state.role == RemoteControlRole.controller)) {
      return;
    }
    if (!canRequestControl) return;
    state.markRequested(asController: true);
    rt.requestControl(callId: callId, toUserId: peerId);
    notify();
  }

  Future<void> rejectRequest(String message) async {
    _error = message;
    _incomingRequest = false;
    _consentDialogOpen = false;
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
    await _publishDisplays();
    // Never XGrabPointer — it eats remote XTest clicks and freezes the host mouse.
    try {
      await RemoteInput.setInputLock(false);
    } catch (_) {}
    hostInputLocked = false;
    rt.grantControl(callId: callId, toUserId: peerId);
    _startHostWatch();
    _startHostClipboardPoll();
    notify();
  }

  void denyControl({String reason = 'Remote control was denied.'}) {
    _incomingRequest = false;
    _consentDialogOpen = false;
    state.markDenied();
    rt.denyControl(callId: callId, toUserId: peerId, reason: reason);
    notify();
  }

  Future<void> revokeControl({bool notifyPeer = true}) async {
    final wasGranted = state.isGranted;
    final wasHost = state.role == RemoteControlRole.host;
    final wasController = state.role == RemoteControlRole.controller;
    final wasPendingHost = !wasGranted &&
        wasHost &&
        (state.auth == RemoteControlAuth.requested || _incomingRequest);
    _incomingRequest = false;
    _consentDialogOpen = false;
    _stopTimers();
    if (wasHost) {
      try {
        await RemoteInput.setInputLock(false);
        hostInputLocked = false;
        await RemoteInput.releaseAll();
      } catch (_) {}
    }
    if (wasController) {
      _sendRaw(RemoteControlProtocol.releaseAll());
    }
    state.markRevoked();
    peerDisplays = const [];
    activeDisplayId = null;
    lastClipboardFromPeer = null;
    if (notifyPeer) {
      if (wasGranted) {
        rt.revokeControl(callId: callId, toUserId: peerId);
      } else if (wasPendingHost) {
        rt.denyControl(
          callId: callId,
          toUserId: peerId,
          reason: 'Remote control was ended.',
        );
      }
    }
    notify();
  }

  void onPeerRequest() {
    // Only the screen-sharing host should see the consent dialog.
    if (!isSharingLocally()) return;
    // Ignore duplicate requests while waiting, showing consent, or granted.
    if (state.isGranted) return;
    if (_incomingRequest || _consentDialogOpen) return;
    if (state.auth == RemoteControlAuth.requested &&
        state.role == RemoteControlRole.host) {
      return;
    }
    _incomingRequest = true;
    state.markRequested(asController: false);
    notify();
  }

  void onPeerGrant() {
    state.markGranted(asController: true);
    _startControllerHeartbeat();
    _startControllerClipboardSync();
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
    final blocked = _isBlockedChord(code: code, mods: mods);
    if (blocked) return;
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

  Future<void> setQuality(RemoteControlQuality mode) async {
    quality = mode;
    if (state.isController) {
      _sendRaw(RemoteControlProtocol.quality(mode));
    } else if (state.isHost) {
      final handler = onQualityRequested;
      if (handler != null) await handler(mode);
    }
    notify();
  }

  Future<void> requestSwitchDisplay(String id) async {
    if (!state.isController || id.isEmpty) return;
    _sendRaw(RemoteControlProtocol.switchDisplay(id));
  }

  Future<void> sendClipboardText(String text) async {
    if (!state.isGranted) return;
    if (text.isEmpty || text == _lastClipSent) return;
    _lastClipSent = text;
    _sendRaw(RemoteControlProtocol.clipboard(text));
  }

  Future<void> updateLocalGeometry(int width, int height) async {
    if (width <= 0 || height <= 0) return;
    state.displayWidth = width;
    state.displayHeight = height;
    if (state.isHost) {
      await _publishGeometry();
    }
  }

  Future<void> publishDisplaysNow({String? activeId}) async {
    if (activeId != null) activeDisplayId = activeId;
    await _publishDisplays();
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

  Future<void> _publishDisplays() async {
    if (!state.isHost) return;
    final lister = listDisplays;
    if (lister == null) return;
    try {
      final list = await lister();
      peerDisplays = list;
      _sendRaw(RemoteControlProtocol.displays(
        list,
        activeId: activeDisplayId,
      ));
      notify();
    } catch (e) {
      debugPrint('remote control list displays failed: $e');
    }
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
    if (t == 'quality') {
      final mode = RemoteControlQualityWire.parse(msg['mode']);
      if (mode == null) return;
      quality = mode;
      if (state.isHost) {
        final handler = onQualityRequested;
        if (handler != null) await handler(mode);
      }
      notify();
      return;
    }
    if (t == 'displays') {
      final rawList = msg['list'];
      if (rawList is List) {
        peerDisplays = rawList
            .map(RemoteDisplayInfo.fromJson)
            .whereType<RemoteDisplayInfo>()
            .toList();
      }
      final active = msg['active'];
      if (active is String && active.isNotEmpty) {
        activeDisplayId = active;
      }
      notify();
      return;
    }
    if (t == 'switch_display') {
      if (!state.isHost) return;
      final id = msg['id'] as String?;
      if (id == null || id.isEmpty) return;
      final handler = onSwitchDisplay;
      if (handler != null) {
        await handler(id);
        activeDisplayId = id;
        await _publishGeometry();
        await _publishDisplays();
      }
      return;
    }
    if (t == 'clip') {
      final text = msg['text'] as String?;
      if (text == null || text.isEmpty) return;
      if (text == _lastClipApplied) return;
      _lastClipApplied = text;
      _lastClipSent = text; // avoid echo-polling it straight back
      lastClipboardFromPeer = text;
      // Web: never touch navigator.clipboard — read/write prompts steal clicks.
      if (kIsWeb) {
        final prev = AppClipboard.onRemembered;
        AppClipboard.onRemembered = null;
        AppClipboard.remember(text);
        AppClipboard.onRemembered = prev;
      } else {
        try {
          await RemoteInput.setClipboardText(text);
        } catch (_) {}
        try {
          await Clipboard.setData(ClipboardData(text: text));
        } catch (_) {}
        AppClipboard.remember(text);
      }
      notify();
      return;
    }

    // Input events are host-only and require a live grant + screen share.
    if (!state.isHost || !isSharingLocally()) return;

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
          // Never drop button-ups — rate-limit only moves / downs.
          final forceAccept = a == 'up';
          if (!state.acceptHostEvent(DateTime.now(), force: forceAccept)) {
            return;
          }
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
          if (!state.acceptHostEvent(DateTime.now())) return;
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
          // Key-ups must always land or OS auto-repeat sticks forever.
          if (!state.acceptHostEvent(DateTime.now(), force: !down)) return;
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
    _heartbeat?.cancel();
    _heartbeatWatch?.cancel();
    _heartbeatWatch = null;
    _heartbeat = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!state.isController) return;
      _sendRaw(RemoteControlProtocol.heartbeat());
    });
  }

  void _startHostWatch() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _heartbeatWatch?.cancel();
    state.noteHeartbeat();
    _heartbeatWatch = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (!state.isHost) return;
      if (state.heartbeatExpired()) {
        await revokeControl();
      }
    });
  }

  void _startHostClipboardPoll() {
    _clipboardPoll?.cancel();
    _clipboardPoll = Timer.periodic(const Duration(milliseconds: 800), (_) {
      unawaited(_pollAndSendClipboard());
    });
  }

  /// Controller → host clipboard. On web: event-driven only (DOM copy / Ctrl+V).
  /// Never poll with clipboard.readText — Chromium's Paste bubble eats clicks.
  void _startControllerClipboardSync() {
    _clipboardPoll?.cancel();
    _clipboardPoll = null;
    if (kIsWeb) {
      AppClipboard.onRemembered = _onAppClipboardRemembered;
      final existing = AppClipboard.peek();
      if (existing != null && existing.isNotEmpty) {
        unawaited(sendClipboardText(existing));
      }
      return;
    }
    _clipboardPoll = Timer.periodic(const Duration(milliseconds: 800), (_) {
      unawaited(_pollAndSendClipboard());
    });
  }

  void _onAppClipboardRemembered(String text) {
    if (!state.isController) return;
    unawaited(sendClipboardText(text));
  }

  Future<void> _pollAndSendClipboard() async {
    if (!state.isGranted || kIsWeb) return;
    try {
      var text = await RemoteInput.getClipboardText();
      if (text == null || text.isEmpty) {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        text = data?.text;
      }
      if (text == null || text.isEmpty) return;
      if (text == _lastClipSent || text == _lastClipApplied) return;
      await sendClipboardText(text);
    } catch (_) {}
  }

  void _stopTimers() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _heartbeatWatch?.cancel();
    _heartbeatWatch = null;
    _moveFlushTimer?.cancel();
    _moveFlushTimer = null;
    _clipboardPoll?.cancel();
    _clipboardPoll = null;
    if (identical(AppClipboard.onRemembered, _onAppClipboardRemembered)) {
      AppClipboard.onRemembered = null;
    }
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
    // Super/Meta alone is allowed (Ubuntu dash / Activities).
    return false;
  }

  Future<void> dispose() async {
    _stopTimers();
    _incomingRequest = false;
    if (state.role == RemoteControlRole.host) {
      try {
        await RemoteInput.setInputLock(false);
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
