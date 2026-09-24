import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../util/low_resource.dart';
import '../util/privet_video_controller.dart';
import '../util/privet_video_prefs.dart';
import 'privet_video_chrome.dart';
import 'privet_video_surface.dart';

/// Full-screen video viewer. When [controller] is already initialized (the
/// inline player hands it over) playback continues without a second open.
/// Otherwise the URL is opened here. Used on every platform — web (official
/// `<video>` backend) and desktop (native backend via fvp).
Future<void> showVideoFullscreen(
  BuildContext context, {
  required String url,
  VideoPlayerController? controller,
  Duration initialPosition = Duration.zero,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close video',
    barrierColor: Colors.black,
    transitionDuration: privetAnim(const Duration(milliseconds: 180)),
    pageBuilder: (ctx, animation, secondaryAnimation) {
      return _VideoFullscreenPage(
        url: url,
        controller: controller,
        initialPosition: initialPosition,
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      if (privetLowResource) return child;
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

class _VideoFullscreenPage extends StatefulWidget {
  const _VideoFullscreenPage({
    required this.url,
    this.controller,
    this.initialPosition = Duration.zero,
  });

  final String url;
  final VideoPlayerController? controller;
  final Duration initialPosition;

  @override
  State<_VideoFullscreenPage> createState() => _VideoFullscreenPageState();
}

class _VideoFullscreenPageState extends State<_VideoFullscreenPage> {
  VideoPlayerController? _controller;
  bool _ownsController = false;
  bool _ready = false;
  bool _failed = false;
  bool _playing = false;
  bool _buffering = false;
  bool _chrome = true;
  Timer? _hideChrome;

  @override
  void initState() {
    super.initState();
    final existing = widget.controller;
    if (existing != null && existing.value.isInitialized) {
      _controller = existing;
      _ownsController = false;
      _ready = true;
      _syncFromController();
      existing.addListener(_onTick);
      _scheduleHide();
    } else {
      _init();
    }
  }

  Future<void> _init() async {
    final controller = createPrivetVideoController(widget.url)
      ..setLooping(false);
    _ownsController = true;
    try {
      await controller.initialize();
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      tunePrivetVideoController(controller);
      await PrivetVideoPrefs.apply(controller);
      if (widget.initialPosition > Duration.zero) {
        await controller.seekTo(widget.initialPosition);
      }
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      _controller = controller;
      _controller!.addListener(_onTick);
      _ready = true;
      _syncFromController();
      setState(() {});
      await controller.play();
      _scheduleHide();
    } catch (_) {
      unawaited(controller.dispose());
      if (!mounted) return;
      _failed = true;
      setState(() {});
    }
  }

  void _syncFromController() {
    final controller = _controller;
    if (controller == null) return;
    _playing = controller.value.isPlaying;
    _buffering = controller.value.isBuffering;
  }

  void _onTick() {
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
    if (playing) {
      _scheduleHide();
    } else {
      _hideChrome?.cancel();
      if (!_chrome) setState(() => _chrome = true);
    }
  }

  void _scheduleHide() {
    _hideChrome?.cancel();
    if (!_playing) return;
    _hideChrome = Timer(const Duration(milliseconds: 2400), () {
      if (!mounted || !_playing) return;
      setState(() => _chrome = false);
    });
  }

  void _revealChrome() {
    if (!_chrome) setState(() => _chrome = true);
    _scheduleHide();
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    _revealChrome();
  }

  Future<void> _nudge(Duration delta) async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    final duration = controller.value.duration;
    var next = controller.value.position + delta;
    if (next < Duration.zero) next = Duration.zero;
    if (duration > Duration.zero && next > duration) next = duration;
    await controller.seekTo(next);
    _revealChrome();
  }

  Future<void> _nudgeVolume(double delta) async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    PrivetVideoPrefs.muted = false;
    PrivetVideoPrefs.volume =
        (PrivetVideoPrefs.volume + delta).clamp(0.0, 1.0);
    await controller.setVolume(PrivetVideoPrefs.effectiveVolume);
    if (mounted) setState(() {});
    _revealChrome();
  }

  void _close() => Navigator.of(context).maybePop();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyK) {
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.keyJ) {
      unawaited(_nudge(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyL) {
      unawaited(_nudge(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(_nudgeVolume(0.1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_nudgeVolume(-0.1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      PrivetVideoPrefs.muted = !PrivetVideoPrefs.muted;
      final controller = _controller;
      if (controller != null) {
        unawaited(controller.setVolume(PrivetVideoPrefs.effectiveVolume));
      }
      if (mounted) setState(() {});
      _revealChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onDoubleTap(TapDownDetails details, Size size) {
    final x = details.localPosition.dx;
    if (x < size.width / 3) {
      unawaited(_nudge(const Duration(seconds: -10)));
    } else if (x > size.width * 2 / 3) {
      unawaited(_nudge(const Duration(seconds: 10)));
    } else {
      unawaited(_togglePlay());
    }
  }

  @override
  void dispose() {
    _hideChrome?.cancel();
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onTick);
      if (_ownsController) controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        onHover: (_) => _revealChrome(),
        cursor: _chrome ? SystemMouseCursors.basic : SystemMouseCursors.none,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
              ),
              if (_failed)
                const Center(
                  child: Text(
                    'Video unavailable',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
              if (!_ready && !_failed)
                const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              if (_ready && controller != null)
                Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _togglePlay,
                          onDoubleTapDown: (details) =>
                              _onDoubleTap(details, size),
                          child: PrivetVideoSurface(controller: controller),
                        ),
                      );
                    },
                  ),
                ),
              if (_ready && _buffering)
                const Center(
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  ),
                ),
              if (_ready && !_playing)
                Center(
                  child: _PlayBadge(
                    size: 64,
                    iconSize: 40,
                    onPressed: _togglePlay,
                  ),
                ),
              if (_ready && controller != null)
                AnimatedOpacity(
                  opacity: _chrome ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_chrome,
                    child: SafeArea(
                      child: Stack(
                        children: [
                          Align(
                            alignment: Alignment.topRight,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: _TopClose(onPressed: _close),
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: PrivetVideoChrome(
                              controller: controller,
                              dense: false,
                              playing: _playing,
                              showSpeed: true,
                              showSkip: true,
                              onPlayPause: _togglePlay,
                              onSkip: _nudge,
                              onToggleFullscreen: _close,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge({
    this.size = 52,
    this.iconSize = 32,
    this.onPressed,
  });

  final double size;
  final double iconSize;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.play_arrow_rounded,
        size: iconSize,
        color: Colors.white,
      ),
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

class _TopClose extends StatelessWidget {
  const _TopClose({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Exit fullscreen',
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: 'Exit fullscreen',
          onPressed: onPressed,
          mouseCursor: SystemMouseCursors.click,
          icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white),
          iconSize: 22,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ),
    );
  }
}
