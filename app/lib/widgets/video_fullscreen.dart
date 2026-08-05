import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';
import '../util/low_resource.dart';

/// Full-screen video viewer: black backdrop, centered video, play/pause,
/// scrub bar with time, and exit-fullscreen buttons. Used by the inline
/// player's fullscreen control on every platform — web (official <video>
/// backend) and desktop (native backend via fvp).
Future<void> showVideoFullscreen(
  BuildContext context, {
  required String url,
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
    this.initialPosition = Duration.zero,
  });

  final String url;
  final Duration initialPosition;

  @override
  State<_VideoFullscreenPage> createState() => _VideoFullscreenPageState();
}

class _VideoFullscreenPageState extends State<_VideoFullscreenPage> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final controller =
        VideoPlayerController.networkUrl(Uri.parse(widget.url))
          ..setLooping(false);
    try {
      await controller.initialize();
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      _controller = controller;
      _controller!.addListener(_onTick);
      if (widget.initialPosition > Duration.zero) {
        await controller.seekTo(widget.initialPosition);
      }
      _ready = true;
      if (mounted) setState(() {});
      await controller.play();
    } catch (_) {
      unawaited(controller.dispose());
      if (!mounted) return;
      _failed = true;
      setState(() {});
    }
  }

  void _onTick() {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null) return;
    final playing = controller.value.isPlaying;
    if (playing != _playing) setState(() => _playing = playing);
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null || !_ready) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  void _close() => Navigator.of(context).maybePop();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(_togglePlay());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onTick);
      controller.dispose();
    }
    super.dispose();
  }

  static String _fmt(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
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
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _togglePlay,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: controller.value.size.width,
                        height: controller.value.size.height,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  ),
                ),
              ),
            if (_ready && !_playing)
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: _VideoChromeButton(
                    tooltip: 'Exit fullscreen',
                    icon: Icons.fullscreen_exit_rounded,
                    onPressed: _close,
                  ),
                ),
              ),
            ),
            if (_ready && controller != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.62),
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 36, 12, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        colors: VideoProgressColors(
                          playedColor: PrivetTheme.signal,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _VideoChromeButton(
                            tooltip: _playing ? 'Pause' : 'Play',
                            icon: _playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            onPressed: _togglePlay,
                          ),
                          const SizedBox(width: 10),
                          ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: controller,
                            builder: (context, value, _) {
                              return Text(
                                '${_fmt(value.position)} / ${_fmt(value.duration)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              );
                            },
                          ),
                          const Spacer(),
                          _VideoChromeButton(
                            tooltip: 'Exit fullscreen',
                            icon: Icons.fullscreen_exit_rounded,
                            onPressed: _close,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VideoChromeButton extends StatelessWidget {
  const _VideoChromeButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          mouseCursor: SystemMouseCursors.click,
          icon: Icon(icon, color: Colors.white),
          iconSize: 22,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ),
    );
  }
}
