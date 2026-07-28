import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../util/remote_input.dart';
import '../util/webrtc_safe.dart';
import '../util/web_select_cursor.dart';
import '../widgets/avatar.dart';
import '../widgets/immersive_control_chrome.dart';
import '../widgets/remote_control_layer.dart';
import '../widgets/screen_share_picker.dart';

/// Human label for the current call transport.
String _modeLabel(String mode) {
  switch (mode) {
    case 'audio':
      return 'Audio call';
    case 'screen':
      return 'Screen share';
    case 'control':
      return 'Remote control';
    default:
      return 'Video call';
  }
}

IconData _modeIcon(String mode) {
  switch (mode) {
    case 'audio':
      return Icons.call_rounded;
    case 'screen':
      return Icons.screen_share_rounded;
    case 'control':
      return Icons.mouse_rounded;
    default:
      return Icons.videocam_rounded;
  }
}

Future<void> _acceptRemoteControlInvite(
  BuildContext context,
  PrivetState state,
) async {
  final cap = await RemoteInput.probe();
  if (!cap.canInject) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PrivetTheme.panel,
        title: Text(
          'Cannot allow remote control',
          style: GoogleFonts.syne(fontWeight: FontWeight.w700),
        ),
        content: Text(
          cap.detail.isNotEmpty
              ? cap.detail
              : 'Use the Linux or Windows Privet app to let someone control your screen. A browser tab cannot move your mouse or type on your behalf.',
          style: TextStyle(color: PrivetTheme.mist, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    state.rejectIncoming();
    return;
  }

  if (!context.mounted) return;
  MediaStream? stream;
  try {
    stream = await showScreenSharePicker(context, screensOnly: true);
  } catch (e) {
    state.setError('$e');
    return;
  }
  if (stream == null) return; // cancelled — stay ringing

  try {
    await RemoteInput.ensureReady();
  } catch (e) {
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
    state.setError('Could not enable OS input for remote control: $e');
    return;
  }

  await state.acceptRemoteControl(displayStream: stream);
}

class CallOverlay extends StatelessWidget {
  const CallOverlay({super.key, required this.state});

  final PrivetState state;

  @override
  Widget build(BuildContext context) {
    final session = state.callSession;
    final ring = state.ringing;

    if (session != null) {
      if (state.callMinimized) {
        return _DraggableMiniCallBar(state: state, session: session);
      }
      return _ActiveCallView(state: state, session: session);
    }
    if (ring != null) {
      return _RingingView(state: state);
    }
    return const SizedBox.shrink();
  }
}

// ───────────────────────────── Mini / floating bar ──────────────────────────

/// Teams-style floating presenter / in-call bar (draggable + resizable).
class _DraggableMiniCallBar extends StatefulWidget {
  const _DraggableMiniCallBar({required this.state, required this.session});

  final PrivetState state;
  final CallSession session;

  @override
  State<_DraggableMiniCallBar> createState() => _DraggableMiniCallBarState();
}

class _DraggableMiniCallBarState extends State<_DraggableMiniCallBar> {
  Offset? _dragOrigin;
  Offset? _positionOrigin;
  Size? _sizeOrigin;
  Offset? _localOffset;
  Size? _localSize;

  Offset _defaultOffset(Size screen) {
    final size = _localSize ?? widget.state.miniCallSize;
    return Offset(
      (screen.width - size.width - 16).clamp(8.0, screen.width - size.width),
      (screen.height - size.height - 16).clamp(8.0, screen.height - size.height),
    );
  }

  @override
  void initState() {
    super.initState();
    _localOffset = widget.state.miniCallOffset;
    _localSize = widget.state.miniCallSize;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final compact = PrivetTheme.isCompact(context);
    final size = _localSize ?? widget.state.miniCallSize;
    final offset = _localOffset ?? widget.state.miniCallOffset ?? _defaultOffset(screen);

    if (compact) {
      return Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SafeArea(
          top: false,
          child: _MiniCallBar(
            state: widget.state,
            session: widget.session,
            width: screen.width,
            height: 76,
            showResizeHandle: false,
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned(
          left: offset.dx,
          top: offset.dy,
          child: _MiniCallBar(
            state: widget.state,
            session: widget.session,
            width: size.width,
            height: size.height,
            onDragStart: (details) {
              _dragOrigin = details.globalPosition;
              _positionOrigin = offset;
            },
            onDragUpdate: (details) {
              final drag = _dragOrigin;
              final pos = _positionOrigin;
              if (drag == null || pos == null) return;
              final delta = details.globalPosition - drag;
              final next = Offset(
                (pos.dx + delta.dx).clamp(0.0, screen.width - size.width),
                (pos.dy + delta.dy).clamp(0.0, screen.height - size.height),
              );
              setState(() => _localOffset = next);
            },
            onDragEnd: (_) {
              _dragOrigin = null;
              _positionOrigin = null;
              widget.state.commitMiniCallLayout(offset: _localOffset);
            },
            onResizeStart: (details) {
              _dragOrigin = details.globalPosition;
              _sizeOrigin = size;
              _positionOrigin = offset;
            },
            onResizeUpdate: (details) {
              final drag = _dragOrigin;
              final origin = _sizeOrigin;
              final pos = _positionOrigin;
              if (drag == null || origin == null || pos == null) return;
              final delta = details.globalPosition - drag;
              final raw = Size(
                origin.width - delta.dx,
                origin.height - delta.dy,
              );
              final nextSize = Size(
                raw.width.clamp(320.0, 720.0),
                raw.height.clamp(96.0, 520.0),
              );
              final nextOffset = Offset(
                (pos.dx + origin.width - nextSize.width)
                    .clamp(0.0, screen.width - nextSize.width),
                (pos.dy + origin.height - nextSize.height)
                    .clamp(0.0, screen.height - nextSize.height),
              );
              setState(() {
                _localSize = nextSize;
                _localOffset = nextOffset;
              });
            },
            onResizeEnd: (_) {
              _dragOrigin = null;
              _sizeOrigin = null;
              _positionOrigin = null;
              widget.state.commitMiniCallLayout(
                offset: _localOffset,
                size: _localSize,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MiniCallBar extends StatelessWidget {
  const _MiniCallBar({
    required this.state,
    required this.session,
    required this.width,
    required this.height,
    this.showResizeHandle = true,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onResizeStart,
    this.onResizeUpdate,
    this.onResizeEnd,
  });

  final PrivetState state;
  final CallSession session;
  final double width;
  final double height;
  final bool showResizeHandle;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final GestureDragStartCallback? onResizeStart;
  final GestureDragUpdateCallback? onResizeUpdate;
  final GestureDragEndCallback? onResizeEnd;

  @override
  Widget build(BuildContext context) {
    final mode = session.call.mode;
    final sharing = session.isSharingLocally;
    final isScreen = session.isScreenLike;

    // Any live video worth previewing — decoupled from call *mode* so a screen
    // share started during an audio call still lights up the tile.
    final hostingControl = session.isRemoteHost ||
        (session.isControlCall && sharing);
    final localCamLive = session.hasCamTrack &&
        session.camOn &&
        !sharing &&
        session.localRenderer.srcObject != null;
    final remoteVideo = session.remoteHasVideo &&
        !session.showShareStopped &&
        !sharing &&
        session.remoteRenderer.srcObject != null;
    // While I share / control host: status chrome only — no capture tile,
    // no stale peer last-frame.
    final showLocalPreview =
        !hostingControl && !sharing && !remoteVideo && localCamLive;
    final showVideo = remoteVideo || showLocalPreview;
    final videoRenderer =
        (showLocalPreview) ? session.localRenderer : session.remoteRenderer;
    final videoIsScreen =
        showLocalPreview && sharing ? true : (isScreen || session.peerSharingScreen);

    final label = mode == 'control'
        ? (sharing
            ? 'Being controlled'
            : session.remoteControlActive
                ? 'Controlling'
                : session.showShareStopped
                    ? 'Share stopped'
                    : 'Remote control')
        : mode == 'screen'
            ? (sharing
                ? 'Sharing screen'
                : session.showShareStopped
                    ? 'Share stopped'
                    : remoteVideo
                        ? 'Watching screen'
                        : 'Screen call')
            : sharing
                ? 'Sharing screen'
                : session.peerSharingScreen && remoteVideo
                    ? 'Watching screen'
                    : mode == 'video'
                        ? 'Video call'
                        : 'Audio call';

    const railW = 220.0;
    final videoH = (height - 24).clamp(72.0, height - 24);

    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MiniIconBtn(
          icon: !session.hasMicTrack || !session.micOn
              ? Icons.mic_off_rounded
              : Icons.mic_rounded,
          color: !session.hasMicTrack
              ? PrivetTheme.panel
              : session.micOn
                  ? PrivetTheme.panel
                  : PrivetTheme.danger,
          enabled: true,
          tooltip: !session.hasMicTrack
              ? 'Enable microphone'
              : session.micOn
                  ? 'Mute'
                  : 'Unmute',
          onTap: session.toggleMic,
        ),
        if (!session.isControlCall)
          _MiniIconBtn(
            icon: sharing
                ? Icons.stop_screen_share_rounded
                : Icons.screen_share_rounded,
            color: sharing ? const Color(0xFFFFA726) : PrivetTheme.signal,
            ink: !sharing,
            enabled: sharing || session.canStartScreenShare,
            tooltip: sharing
                ? 'Stop sharing'
                : session.canStartScreenShare
                    ? 'Share screen'
                    : 'Peer sharing',
            onTap: () async {
              if (sharing) {
                await session.toggleScreenShare();
                return;
              }
              final stream = await showScreenSharePicker(context);
              if (stream != null) {
                await session.startScreenShare(stream);
              }
            },
          ),
        _MiniIconBtn(
          icon: Icons.open_in_full_rounded,
          color: PrivetTheme.signal,
          ink: true,
          tooltip: session.isControlCall && session.remoteControlActive
              ? 'Expand to control'
              : 'Maximize',
          onTap: () => state.setCallMinimized(false),
        ),
        _MiniIconBtn(
          icon: Icons.call_end_rounded,
          color: PrivetTheme.danger,
          tooltip: 'Leave',
          onTap: () => state.endCall(),
        ),
      ],
    );

    final nameBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          session.peer.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: GoogleFonts.syne(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: PrivetTheme.paper,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: TextStyle(
            color: PrivetTheme.mist,
            fontSize: 11,
          ),
        ),
      ],
    );

    final preview = sharing && !hostingControl
        ? Container(
            height: videoH,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  PrivetTheme.signal.withValues(alpha: 0.18),
                  PrivetTheme.panel,
                ],
              ),
              border: Border.all(
                color: PrivetTheme.signal.withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.screen_share_rounded,
                  color: PrivetTheme.signal,
                  size: (videoH * 0.28).clamp(22.0, 36.0),
                ),
                const SizedBox(height: 6),
                Text(
                  'Presenting',
                  style: GoogleFonts.syne(
                    color: PrivetTheme.paper,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'to ${session.peer.displayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: PrivetTheme.mist,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          )
        : showVideo
            ? ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ColoredBox(
                  color: Colors.black,
                  child: SizedBox(
                    height: videoH,
                    width: double.infinity,
                    child: RTCVideoView(
                      videoRenderer,
                      mirror: showLocalPreview,
                      objectFit: videoIsScreen
                          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                          : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              )
            : Container(
                height: videoH,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: PrivetTheme.panel,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    PrivetAvatar(
                      name: session.peer.displayName,
                      hue: session.peer.avatarHue,
                      size: (videoH * 0.35).clamp(28.0, 56.0),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      session.showShareStopped ? 'Share stopped' : label,
                      style: TextStyle(
                        color: PrivetTheme.mist,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              );

    return Material(
      elevation: 16,
      shadowColor: Colors.black54,
      color: const Color(0xFF1F1F1F),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                onEnter: (_) => setPrivetDragHover(true),
                onExit: (_) => setPrivetDragHover(false),
                child: GestureDetector(
                  onPanStart: onDragStart,
                  onPanUpdate: onDragUpdate,
                  onPanEnd: onDragEnd,
                  child: InkWell(
                    onTap: () => state.setCallMinimized(false),
                    mouseCursor: SystemMouseCursors.move,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                      child: Row(
                        children: [
                          Expanded(child: preview),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: railW,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(height: 46),
                                const SizedBox(height: 10),
                                nameBlock,
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 10,
              top: 0,
              bottom: 0,
              width: railW,
              child: Align(
                alignment: Alignment.centerRight,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) => setPrivetDragHover(false),
                      onExit: (_) => setPrivetDragHover(false),
                      child: controls,
                    ),
                    const SizedBox(height: 10),
                    IgnorePointer(
                      child: Opacity(opacity: 0, child: nameBlock),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              child: showResizeHandle
                  ? GestureDetector(
                      onPanStart: (d) {
                        setPrivetDragHover(false);
                        onResizeStart?.call(d);
                      },
                      onPanUpdate: onResizeUpdate,
                      onPanEnd: (d) {
                        onResizeEnd?.call(d);
                        setPrivetDragHover(false);
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpLeft,
                        onEnter: (_) => setPrivetDragHover(false),
                        onExit: (_) => setPrivetDragHover(false),
                        child: Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.topLeft,
                          padding: const EdgeInsets.only(left: 5, top: 5),
                          color: Colors.transparent,
                          child: Icon(
                            Icons.north_west_rounded,
                            size: 16,
                            color: PrivetTheme.paper.withValues(alpha: 0.92),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniIconBtn extends StatelessWidget {
  const _MiniIconBtn({
    required this.icon,
    required this.color,
    required this.onTap,
    this.enabled = true,
    this.ink = false,
    this.tooltip,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool enabled;
  final bool ink;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: SizedBox(
            width: 46,
            height: 46,
            child: Icon(
              icon,
              size: 22,
              color: (ink ? PrivetTheme.ink : PrivetTheme.paper)
                  .withValues(alpha: enabled ? 1 : 0.35),
            ),
          ),
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}

// ───────────────────────────── Ringing / incoming ───────────────────────────

class _RingingView extends StatefulWidget {
  const _RingingView({required this.state});
  final PrivetState state;

  @override
  State<_RingingView> createState() => _RingingViewState();
}

class _RingingViewState extends State<_RingingView> {
  final _preview = RTCVideoRenderer();
  MediaStream? _bound;
  bool _ready = false;

  PrivetState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _initPreview();
  }

  @override
  void didUpdateWidget(covariant _RingingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPreview();
  }

  Future<void> _initPreview() async {
    await _preview.initialize();
    if (!mounted) return;
    setState(() => _ready = true);
    _syncPreview();
  }

  void _syncPreview() {
    if (!_ready) return;
    final stream = state.pendingLocalStream;
    final hasVideo = stream?.getVideoTracks().isNotEmpty == true;
    if (!hasVideo) {
      if (_bound != null) {
        _preview.srcObject = null;
        _bound = null;
      }
      return;
    }
    if (identical(_bound, stream)) return;
    _bound = stream;
    _preview.srcObject = stream;
    unawaited(muteLocalRenderer(_preview));
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _preview.srcObject = null;
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = state.ringing!;
    final incoming = ring.phase == CallPhase.incoming;
    final mode = ring.call.mode;
    final videoInvite = mode == 'video';
    final compact = PrivetTheme.isCompact(context);
    final showSelfPreview = !incoming &&
        videoInvite &&
        _ready &&
        _bound != null &&
        _preview.srcObject != null;

    final title = incoming
        ? (mode == 'control'
            ? '${ring.peer.displayName} wants to control your screen'
            : 'Incoming ${_modeLabel(mode).toLowerCase()}')
        : mode == 'screen'
            ? 'Sharing screen…'
            : mode == 'control'
                ? 'Waiting for them to allow control…'
                : 'Ringing…';

    final peerBlock = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!showSelfPreview) ...[
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  PrivetTheme.signal.withValues(alpha: 0.35),
                  PrivetTheme.signal.withValues(alpha: 0.0),
                ],
              ),
            ),
            child: PrivetAvatar(
              name: ring.peer.displayName,
              hue: ring.peer.avatarHue,
              size: compact ? 104 : 120,
            ),
          ),
          const SizedBox(height: 22),
        ],
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_modeIcon(mode),
                size: 16, color: PrivetTheme.signal),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                (incoming && mode == 'control'
                        ? 'Remote control request'
                        : title)
                    .toUpperCase(),
                textAlign: TextAlign.center,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 12,
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w700,
                  color: PrivetTheme.signal,
                  shadows: showSelfPreview
                      ? const [Shadow(blurRadius: 10, color: Colors.black87)]
                      : null,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          ring.peer.displayName,
          textAlign: TextAlign.center,
          style: GoogleFonts.syne(
            fontSize: showSelfPreview ? 26 : 32,
            fontWeight: FontWeight.w800,
            color: PrivetTheme.paper,
            shadows: showSelfPreview
                ? const [Shadow(blurRadius: 14, color: Colors.black87)]
                : null,
          ),
        ),
        if (incoming && mode == 'control') ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Allowing shares your screen and lets them move your mouse and type. Use the Linux or Windows Privet app.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: showSelfPreview ? PrivetTheme.paper : PrivetTheme.mist,
                fontSize: 13,
                height: 1.35,
                shadows: showSelfPreview
                    ? const [Shadow(blurRadius: 10, color: Colors.black87)]
                    : null,
              ),
            ),
          ),
        ],
        if (ring.peer.handle.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '@${ring.peer.handle}',
            style: TextStyle(
              color: showSelfPreview ? PrivetTheme.paper : PrivetTheme.mist,
              fontSize: 14,
              shadows: showSelfPreview
                  ? const [Shadow(blurRadius: 10, color: Colors.black87)]
                  : null,
            ),
          ),
        ],
      ],
    );

    final actions = Wrap(
      alignment: WrapAlignment.center,
      spacing: compact ? 20 : 28,
      runSpacing: 18,
      children: [
        if (incoming) ...[
          _CallButton(
            color: PrivetTheme.danger,
            icon: Icons.call_end_rounded,
            label: 'Decline',
            big: true,
            onTap: state.rejectIncoming,
          ),
          if (mode == 'control')
            _CallButton(
              color: PrivetTheme.signal,
              icon: Icons.mouse_rounded,
              label: 'Allow control',
              ink: true,
              big: true,
              onTap: () => _acceptRemoteControlInvite(context, state),
            )
          else if (videoInvite) ...[
            _CallButton(
              color: PrivetTheme.panelElevated,
              icon: Icons.call_rounded,
              label: 'Answer audio',
              big: true,
              onTap: () => state.acceptIncoming(withVideo: false),
            ),
            _CallButton(
              color: PrivetTheme.signal,
              icon: Icons.videocam_rounded,
              label: 'Answer video',
              ink: true,
              big: true,
              onTap: () => state.acceptIncoming(withVideo: true),
            ),
          ] else
            _CallButton(
              color: PrivetTheme.signal,
              icon: Icons.call_rounded,
              label: 'Accept',
              ink: true,
              big: true,
              onTap: () => state.acceptIncoming(withVideo: false),
            ),
        ] else
          _CallButton(
            color: PrivetTheme.danger,
            icon: Icons.call_end_rounded,
            label: 'Cancel',
            big: true,
            onTap: () => state.endCall(local: true),
          ),
      ],
    );

    return Material(
      color: PrivetTheme.ink.withValues(alpha: 0.96),
      child: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showSelfPreview)
              RTCVideoView(
                _preview,
                mirror: true,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              )
            else
              const _AmbientBackdrop(),
            if (showSelfPreview)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x99000000),
                      Color(0x33000000),
                      Color(0xCC000000),
                    ],
                    stops: [0, 0.45, 1],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  peerBlock,
                  const Spacer(flex: 4),
                  actions,
                  SizedBox(height: compact ? 28 : 44),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Subtle radial glow behind avatars when there's no live video.
class _AmbientBackdrop extends StatelessWidget {
  const _AmbientBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.35),
          radius: 1.1,
          colors: [
            Color(0xFF17202A),
            PrivetTheme.ink,
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── Active in-call view ──────────────────────────

class _ActiveCallView extends StatefulWidget {
  const _ActiveCallView({required this.state, required this.session});
  final PrivetState state;
  final CallSession session;

  @override
  State<_ActiveCallView> createState() => _ActiveCallViewState();
}

class _ActiveCallViewState extends State<_ActiveCallView> {
  bool _pipShown = false;
  Offset? _pipPos;
  Offset? _pipDragOrigin;
  Offset? _pipPosOrigin;
  Timer? _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _elapsedLabel {
    final h = _elapsed.inHours;
    final m = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final session = widget.session;
    final screen = MediaQuery.sizeOf(context);
    final compact = PrivetTheme.isCompact(context);

    final mode = session.call.mode;
    final isScreenCall = session.isScreenLike;
    final sharing = session.isSharingLocally;
    final shareStopped = session.showShareStopped;

    // Live local camera (not while screen-sharing — that replaces the sender).
    final localCamLive = session.hasCamTrack &&
        session.camOn &&
        !sharing &&
        session.localRenderer.srcObject != null;
    // Require a live srcObject — a null/detached renderer paints black on
    // native OpenGL (and a frozen last frame on web) if we keep RTCVideoView.
    // While presenting, never stage peer video — leftover last-share frames
    // looked like "watching them" under a tiny "you are sharing" label.
    final remoteVideo = session.remoteHasVideo &&
        !shareStopped &&
        !sharing &&
        session.remoteRenderer.srcObject != null;
    final remoteIsScreen = isScreenCall || session.peerSharingScreen;

    // Hosting control: never stage our own capture — it nests in the stream.
    final hostingControl = session.isRemoteHost ||
        (session.isControlCall && sharing);
    final stageIsRemote = !hostingControl && remoteVideo;
    final stageIsLocalCam =
        !hostingControl && !sharing && !remoteVideo && localCamLive;
    final hasStageVideo = stageIsRemote || stageIsLocalCam;

    // Camera PiP only when we actually have a live camera on a video stage.
    final showSelfPip = localCamLive && stageIsRemote;
    final showPip = showSelfPip;

    // Re-bind renderers when the PiP (re)appears — flutter_webrtc reuses one
    // <video> element per renderer and can leave a frozen/black frame on web;
    // native Texture remounts need the same one-shot srcObject rebind.
    if (showPip && !_pipShown) {
      _pipShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        session.rebindRenderers();
      });
    } else if (!showPip) {
      _pipShown = false;
    }

    RTCVideoRenderer stageRenderer;
    bool stageMirror;
    bool stageContain;
    if (stageIsRemote) {
      stageRenderer = session.remoteRenderer;
      stageMirror = false;
      stageContain = remoteIsScreen;
    } else {
      // stageIsLocalCam (or placeholder — renderer unused then).
      stageRenderer = session.localRenderer;
      stageMirror = true;
      stageContain = false;
    }

    final statusText = _stageStatus(
      session: session,
      sharing: sharing,
      shareStopped: shareStopped,
      isScreenCall: isScreenCall,
      mode: mode,
      remoteVideo: remoteVideo,
    );

    final immersive = session.isControlCall ||
        (session.remoteControlActive &&
            (session.isRemoteController || session.isRemoteHost));

    // ── Stage ──
    final Widget stage;
    if (sharing && !hostingControl) {
      // Presenting status — stop control lives only in the bottom dock.
      stage = _PresentingStage(
        session: session,
        elapsed: _elapsedLabel,
      );
    } else if (hasStageVideo) {
      stage = RTCVideoView(
        stageRenderer,
        mirror: stageMirror,
        objectFit: stageContain
            ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
            : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        placeholderBuilder: (_) => _StagePlaceholder(
          session: session,
          status: statusText,
          shareStopped: shareStopped,
        ),
      );
    } else {
      stage = _StagePlaceholder(
        session: session,
        status: statusText,
        shareStopped: shareStopped,
      );
    }

    // ── Self PiP (live camera only) ──
    final pipW = compact ? 104.0 : 150.0;
    final pipH = compact ? 148.0 : 210.0;
    final defaultPip = Offset(
      screen.width - pipW - 16,
      screen.height - pipH - (compact ? 150 : 130),
    );
    final pipPos = _pipPos == null
        ? defaultPip
        : Offset(
            _pipPos!.dx.clamp(8.0, screen.width - pipW - 8),
            _pipPos!.dy.clamp(60.0, screen.height - pipH - 100),
          );

    Widget? pip;
    if (showPip && !immersive) {
      pip = Positioned(
        left: pipPos.dx,
        top: pipPos.dy,
        child: GestureDetector(
          onPanStart: (d) {
            _pipDragOrigin = d.globalPosition;
            _pipPosOrigin = pipPos;
          },
          onPanUpdate: (d) {
            final o = _pipDragOrigin;
            final p = _pipPosOrigin;
            if (o == null || p == null) return;
            setState(() => _pipPos = p + (d.globalPosition - o));
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: _PipTile(
              renderer: session.localRenderer,
              mirror: true,
              label: 'You',
              width: pipW,
              height: pipH,
            ),
          ),
        ),
      );
    }

    return Material(
      color: PrivetTheme.ink,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RemoteControlLayer(
            session: session,
            state: state,
            immersive: immersive,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: Colors.black, child: stage),
                ),
                if (!immersive) ...[
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: 120,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x99000000), Color(0x00000000)],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 200,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0xB3000000), Color(0x00000000)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                ?pip,
                if (!immersive) ...[
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: _CallHeader(
                                session: session,
                                elapsed: _elapsedLabel,
                                sharing: sharing,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Tooltip(
                              message: 'Minimize',
                              child: _GlassIconButton(
                                icon: Icons.close_fullscreen_rounded,
                                onTap: () => state.setCallMinimized(true),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: compact ? 18 : 30),
                        child: _ControlDock(
                          state: state,
                          session: session,
                          compact: compact,
                        ),
                      ),
                    ),
                  ),
                ],
                if (session.error != null || session.remoteControlError != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: immersive ? 64 : (compact ? 120 : 132),
                    child: _ErrorBanner(
                      message: session.error ?? session.remoteControlError!,
                    ),
                  ),
              ],
            ),
          ),
          if (immersive)
            Positioned.fill(
              child: ImmersiveControlChrome(
                state: state,
                session: session,
                elapsed: _elapsedLabel,
              ),
            ),
        ],
      ),
    );
  }

  String _stageStatus({
    required CallSession session,
    required bool sharing,
    required bool shareStopped,
    required bool isScreenCall,
    required String mode,
    required bool remoteVideo,
  }) {
    if (shareStopped) {
      return 'Share stopped';
    }
    if (sharing) {
      return session.isControlCall
          ? (session.ready
              ? 'You are sharing — remote control active'
              : 'Starting remote control…')
          : (session.ready ? "You're sharing" : 'Starting share…');
    }
    if (session.isControlCall) {
      if (session.remoteControlActive) {
        return 'Controlling their screen';
      }
      return remoteVideo
          ? 'Connected — waiting for control…'
          : 'Waiting for their screen…';
    }
    if (isScreenCall) {
      return remoteVideo ? 'Watching their screen' : 'Waiting for screen…';
    }
    if (mode == 'video') {
      if (session.joinedAudioOnly) {
        return 'On audio — tap the camera to go live';
      }
      if (session.cameraPending) {
        return 'Camera unavailable — tap the camera to retry';
      }
      return 'Connecting…';
    }
    return 'On call';
  }
}

/// Peer identity + call status pill shown top-left of the stage.
class _CallHeader extends StatelessWidget {
  const _CallHeader({
    required this.session,
    required this.elapsed,
    required this.sharing,
  });

  final CallSession session;
  final String elapsed;
  final bool sharing;

  @override
  Widget build(BuildContext context) {
    final mode = session.call.mode;
    final statusLine = session.isControlCall
        ? (sharing
            ? 'Remote control • $elapsed'
            : session.remoteControlActive
                ? 'Controlling • $elapsed'
                : 'Remote control • $elapsed')
        : sharing
            ? 'You are sharing • $elapsed'
            : session.peerSharingScreen && session.remoteHasVideo
                ? 'Watching share • $elapsed'
                : '${_modeLabel(mode)} • $elapsed';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PrivetAvatar(
                name: session.peer.displayName,
                hue: session.peer.avatarHue,
                size: 36,
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.peer.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.syne(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: PrivetTheme.paper,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        session.isControlCall
                            ? Icons.mouse_rounded
                            : sharing
                                ? Icons.screen_share_rounded
                                : _modeIcon(mode),
                        size: 12,
                        color: PrivetTheme.signal,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        statusLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: PrivetTheme.mist,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Presenter's stage while local share is active: status + who can see it.
/// Stop sharing lives in the bottom control dock only (no duplicate CTA).
class _PresentingStage extends StatelessWidget {
  const _PresentingStage({
    required this.session,
    required this.elapsed,
  });

  final CallSession session;
  final String elapsed;

  @override
  Widget build(BuildContext context) {
    final peer = session.peer.displayName;
    return Stack(
      fit: StackFit.expand,
      children: [
        const _AmbientBackdrop(),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.15),
              radius: 0.95,
              colors: [
                PrivetTheme.signal.withValues(alpha: 0.14),
                Colors.transparent,
              ],
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: PrivetTheme.signal.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: PrivetTheme.signal.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: PrivetTheme.signal,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color:
                                    PrivetTheme.signal.withValues(alpha: 0.55),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'LIVE · $elapsed',
                          style: GoogleFonts.syne(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: PrivetTheme.paper,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: PrivetTheme.panel.withValues(alpha: 0.85),
                      border: Border.all(
                        color: PrivetTheme.signal.withValues(alpha: 0.35),
                        width: 1.5,
                      ),
                    ),
                    child: Icon(
                      Icons.screen_share_rounded,
                      size: 40,
                      color: PrivetTheme.signal,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    "You're sharing",
                    textAlign: TextAlign.center,
                    style: GoogleFonts.syne(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: PrivetTheme.paper,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Screen, window, or tab — $peer can see what you picked',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: PrivetTheme.mist,
                      fontSize: 14.5,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 26),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      PrivetAvatar(
                        name: session.peer.displayName,
                        hue: session.peer.avatarHue,
                        size: 36,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Sharing with $peer',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: PrivetTheme.paper.withValues(alpha: 0.9),
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Placeholder shown on the stage when there's no live video (audio call,
/// connecting, or a stopped share).
class _StagePlaceholder extends StatelessWidget {
  const _StagePlaceholder({
    required this.session,
    required this.status,
    required this.shareStopped,
  });

  final CallSession session;
  final String status;
  final bool shareStopped;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const _AmbientBackdrop(),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (shareStopped) ...[
                  Icon(
                    Icons.stop_screen_share_rounded,
                    size: 40,
                    color: PrivetTheme.mist.withValues(alpha: 0.85),
                  ),
                  const SizedBox(height: 16),
                ],
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        PrivetTheme.signal.withValues(alpha: 0.28),
                        PrivetTheme.signal.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                  child: PrivetAvatar(
                    name: session.peer.displayName,
                    hue: session.peer.avatarHue,
                    size: 96,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  session.peer.displayName,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.syne(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: PrivetTheme.paper,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: PrivetTheme.mist, fontSize: 14.5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Draggable self / peer preview tile.
class _PipTile extends StatelessWidget {
  const _PipTile({
    required this.renderer,
    required this.mirror,
    required this.label,
    required this.width,
    required this.height,
  });

  final RTCVideoRenderer renderer;
  final bool mirror;
  final String label;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 12,
      shadowColor: Colors.black87,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: PrivetTheme.panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            RTCVideoView(
              renderer,
              mirror: mirror,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: PrivetTheme.paper,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating bottom control dock (mic / camera / share / end).
class _ControlDock extends StatelessWidget {
  const _ControlDock({
    required this.state,
    required this.session,
    required this.compact,
  });

  final PrivetState state;
  final CallSession session;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mode = session.call.mode;
    final sharing = session.isSharingLocally;
    final isControl = session.isControlCall;
    final showCamera = mode == 'video' || isControl;

    final buttons = <Widget>[
      _CallButton(
        color: !session.hasMicTrack
            ? PrivetTheme.panelElevated
            : session.micOn
                ? PrivetTheme.panelElevated
                : PrivetTheme.danger,
        icon: !session.hasMicTrack || !session.micOn
            ? Icons.mic_off_rounded
            : Icons.mic_rounded,
        label: !session.hasMicTrack
            ? 'Mic'
            : session.micOn
                ? 'Mute'
                : 'Unmute',
        enabled: true,
        onTap: session.toggleMic,
      ),
      if (showCamera)
        _CallButton(
          color: !session.hasCamTrack
              ? PrivetTheme.panelElevated
              : session.camOn && !session.sharingScreen
                  ? PrivetTheme.panelElevated
                  : PrivetTheme.danger,
          icon: !session.hasCamTrack || !session.camOn
              ? Icons.videocam_off_rounded
              : Icons.videocam_rounded,
          label: !session.hasCamTrack
              ? 'Camera'
              : session.camOn
                  ? 'Camera'
                  : 'Camera off',
          enabled: !session.sharingScreen,
          onTap:
              session.hasCamTrack ? session.toggleCam : session.retryCamera,
        ),
      if (!isControl)
        _CallButton(
          color: sharing ? const Color(0xFFFFA726) : PrivetTheme.signal,
          icon: sharing
              ? Icons.stop_screen_share_rounded
              : Icons.screen_share_rounded,
          ink: !sharing,
          label: sharing
              ? 'Stop share'
              : (session.peerSharingScreen && !session.remoteShareStopped
                  ? 'Peer sharing'
                  : 'Share'),
          enabled: sharing || session.canStartScreenShare,
          onTap: () async {
            if (sharing) {
              await session.toggleScreenShare();
              return;
            }
            final stream = await showScreenSharePicker(context);
            if (stream != null) {
              await session.startScreenShare(stream);
            }
          },
        ),
      _CallButton(
        color: PrivetTheme.danger,
        icon: Icons.call_end_rounded,
        label: 'Leave',
        onTap: () => state.endCall(),
      ),
    ];

    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 16,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) SizedBox(width: compact ? 8 : 14),
                buttons[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: CircleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        mouseCursor: SystemMouseCursors.click,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 20, color: PrivetTheme.paper),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PrivetTheme.danger.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded,
                color: PrivetTheme.paper, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: PrivetTheme.paper),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Big round call action with a caption underneath.
class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.color,
    required this.icon,
    required this.onTap,
    this.label,
    this.ink = false,
    this.enabled = true,
    this.big = false,
  });

  final Color color;
  final IconData icon;
  final VoidCallback onTap;
  final String? label;
  final bool ink;
  final bool enabled;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final diameter = big ? 66.0 : 56.0;
    final btn = Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        mouseCursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: Icon(
            icon,
            size: big ? 30 : 26,
            color: (ink ? PrivetTheme.ink : PrivetTheme.paper)
                .withValues(alpha: enabled ? 1 : 0.35),
          ),
        ),
      ),
    );
    return SizedBox(
      width: big ? 96 : 78,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn,
          const SizedBox(height: 8),
          SizedBox(
            height: 16,
            child: label == null
                ? null
                : Text(
                    label!,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: PrivetTheme.paper, fontSize: 12),
                  ),
          ),
        ],
      ),
    );
  }
}
