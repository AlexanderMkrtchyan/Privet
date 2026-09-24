import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';
import '../util/agent_debug.dart';
import '../util/privet_video_controller.dart';
import '../util/privet_video_prefs.dart';
import '../util/video_cache.dart';
import 'privet_video_chrome.dart';
import 'privet_video_surface.dart';
import 'video_fullscreen.dart';

/// Plays a remote video inline in the chat bubble.
///
/// When the bubble is on screen the controller is opened so the first frame
/// stays visible under the play badge. [autoInit] also opens immediately
/// (lightbox / focused preview). Hovering starts a short-debounced file
/// prefetch. At most one active player is kept warm via [_activePlayer].
///
/// Web uses the official `video_player` backend; Linux & Windows use the
/// bundled fvp backend (libmdk/FFmpeg), so videos play natively instead of
/// opening the browser. If init still fails the URL is opened externally.
class InlineVideoPlayer extends StatefulWidget {
  const InlineVideoPlayer({
    super.key,
    required this.url,
    this.width = 260,
    this.height = 160,
    this.autoInit = false,
  });

  final String url;
  final double width;
  final double height;

  /// When true, initialize immediately (lightbox / focused preview).
  final bool autoInit;

  @override
  State<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<InlineVideoPlayer> {
  static _InlineVideoPlayerState? _activePlayer;

  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  bool _playing = false;
  bool _buffering = false;
  bool _initializing = false;
  bool _hovered = false;
  bool _handoff = false;
  Timer? _warmTimer;
  Timer? _visibleTimer;
  ScrollPosition? _scrollPosition;

  @override
  void initState() {
    super.initState();
    if (widget.autoInit) {
      _ensureController();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkVisible();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (!identical(next, _scrollPosition)) {
      _scrollPosition?.removeListener(_onScroll);
      _scrollPosition = next;
      _scrollPosition?.addListener(_onScroll);
    }
  }

  void _onScroll() {
    if (_ready || _initializing || _failed) return;
    _visibleTimer?.cancel();
    _visibleTimer = Timer(const Duration(milliseconds: 80), () {
      if (mounted) _checkVisible();
    });
  }

  void _checkVisible() {
    if (!mounted || _ready || _initializing || _failed) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final view = Offset.zero & MediaQuery.sizeOf(context);
    if (!rect.overlaps(view)) return;
    unawaited(_ensureController());
  }

  Future<void> _ensureController() async {
    if (_controller != null || _initializing || _failed) return;
    _initializing = true;
    if (mounted) setState(() {});
    final controller = createPrivetVideoController(widget.url)
      ..setLooping(false);
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      tunePrivetVideoController(controller);
      await PrivetVideoPrefs.apply(controller);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      try {
        await controller.pause();
        await controller.seekTo(Duration.zero);
      } catch (_) {}
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _controller!.addListener(_onControllerTick);
      _ready = true;
      _initializing = false;
      _syncFromController();
      setState(() {});
    } catch (e) {
      // #region agent log
      agentDebugLog(
        hypothesisId: 'H6',
        location: 'inline_video_player.dart:_ensureController',
        message: 'video init failed',
        data: {
          'error': '$e',
          'kIsWeb': kIsWeb,
          'platform': kIsWeb ? 'web' : Platform.operatingSystem,
          'url': widget.url,
        },
      );
      // #endregion
      // Never await dispose() here: when init() throws before the controller's
      // internal _creatingCompleter completes (e.g. MissingPluginException on
      // a platform without a backend), dispose() awaits that completer forever
      // and deadlocks the tap handler.
      unawaited(controller.dispose());
      if (!mounted) return;
      _failed = true;
      _initializing = false;
      setState(() {});
    }
  }

  void _syncFromController() {
    final controller = _controller;
    if (controller == null) return;
    _playing = controller.value.isPlaying;
    _buffering = controller.value.isBuffering;
  }

  void _onControllerTick() {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null) return;
    final playing = controller.value.isPlaying;
    final buffering = controller.value.isBuffering;
    if (playing == _playing && buffering == _buffering) return;
    setState(() {
      _playing = playing;
      _buffering = buffering;
    });
  }

  Future<void> _claimActive() async {
    final prev = _activePlayer;
    if (prev != null && !identical(prev, this)) {
      await prev._pauseAndRelease(keepController: true);
    }
    _activePlayer = this;
  }

  Future<void> _pauseAndRelease({bool keepController = false}) async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    }
    if (!keepController) {
      controller.removeListener(_onControllerTick);
      await controller.dispose();
      _controller = null;
      _ready = false;
      _playing = false;
      _buffering = false;
    }
    if (identical(_activePlayer, this)) _activePlayer = null;
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    // #region agent log
    agentDebugLog(
      hypothesisId: 'H7',
      location: 'inline_video_player.dart:_toggle',
      message: 'video toggle tapped',
      data: {
        'kIsWeb': kIsWeb,
        'platform': kIsWeb ? 'web' : Platform.operatingSystem,
        'ready': _ready,
        'failed': _failed,
        'initializing': _initializing,
        'controllerNull': _controller == null,
        'url': widget.url,
      },
    );
    // #endregion
    await _ensureController();
    final controller = _controller;
    if (controller == null || !_ready) {
      if (_failed) {
        // #region agent log
        agentDebugLog(
          hypothesisId: 'H7',
          location: 'inline_video_player.dart:_toggle',
          message: 'web failed: opening externally',
          data: {'url': widget.url},
        );
        // #endregion
        await _openExternally();
      }
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
      videoCacheReleaseAndWarm(widget.url);
      return;
    }
    await _claimActive();
    videoCacheHold(widget.url);
    await controller.play();
  }

  Future<void> _openExternally() async {
    try {
      await launchUrl(
        Uri.parse(widget.url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  Future<void> _openFullscreen() async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    setState(() => _handoff = true);
    await showVideoFullscreen(
      context,
      url: widget.url,
      controller: controller,
    );
    if (!mounted) return;
    setState(() => _handoff = false);
  }

  @override
  void dispose() {
    _warmTimer?.cancel();
    _visibleTimer?.cancel();
    _scrollPosition?.removeListener(_onScroll);
    videoCacheReleaseAndWarm(widget.url);
    if (identical(_activePlayer, this)) _activePlayer = null;
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      controller.dispose();
    }
    super.dispose();
  }

  bool get _showChrome => !_playing || _hovered || _buffering;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
        _warmTimer?.cancel();
        _warmTimer = Timer(const Duration(milliseconds: 350), () {
          if (!_ready && !_failed) videoCacheWarm(widget.url);
        });
      },
      onExit: (_) {
        _warmTimer?.cancel();
        if (_hovered) setState(() => _hovered = false);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: PrivetTheme.ink,
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: !_ready
                ? Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _toggle,
                      mouseCursor: SystemMouseCursors.click,
                      child: Center(
                        child: _initializing
                            ? SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: PrivetTheme.signal,
                                ),
                              )
                            : _PlayBadge(
                                icon: _failed
                                    ? Icons.open_in_new_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                      ),
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!_handoff)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggle,
                          child: PrivetVideoSurface(controller: _controller!),
                        )
                      else
                        const ColoredBox(color: Colors.black),
                      if (_buffering)
                        const Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _toggle,
                          child: AnimatedOpacity(
                            opacity: _playing ? 0 : 1,
                            duration: const Duration(milliseconds: 160),
                            child: const Center(child: _PlayBadge()),
                          ),
                        ),
                      ),
                      if (!_handoff)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: AnimatedOpacity(
                            opacity: _showChrome ? 1 : 0,
                            duration: const Duration(milliseconds: 160),
                            child: IgnorePointer(
                              ignoring: !_showChrome,
                              child: PrivetVideoChrome(
                                controller: _controller!,
                                dense: true,
                                playing: _playing,
                                onPlayPause: _toggle,
                                onToggleFullscreen: _openFullscreen,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge({
    this.icon = Icons.play_arrow_rounded,
    this.onPressed,
  });

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 32, color: PrivetTheme.signal),
    );
    if (onPressed == null) return badge;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          mouseCursor: SystemMouseCursors.click,
          child: badge,
        ),
      ),
    );
  }
}
