import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';

/// Plays a remote video inline in the chat bubble.
///
/// Controllers are created only after the user taps play (or [autoInit] is
/// true). At most one active player is kept warm via [_activePlayer].
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
  bool _initializing = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoInit) {
      _ensureController();
    }
  }

  Future<void> _ensureController() async {
    if (_controller != null || _initializing || _failed) return;
    _initializing = true;
    if (mounted) setState(() {});
    final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..setLooping(false);
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _controller!.addListener(_onControllerTick);
      _ready = true;
      _initializing = false;
      setState(() {});
    } catch (_) {
      await controller.dispose();
      if (!mounted) return;
      _failed = true;
      _initializing = false;
      setState(() {});
    }
  }

  void _onControllerTick() {
    if (!mounted) return;
    final controller = _controller;
    if (controller == null) return;
    final playing = controller.value.isPlaying;
    if (playing == _playing) return;
    setState(() => _playing = playing);
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
    }
    if (identical(_activePlayer, this)) _activePlayer = null;
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    await _ensureController();
    final controller = _controller;
    if (controller == null || !_ready) return;
    if (controller.value.isPlaying) {
      await controller.pause();
      return;
    }
    await _claimActive();
    await controller.play();
  }

  @override
  void dispose() {
    if (identical(_activePlayer, this)) _activePlayer = null;
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onControllerTick);
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: PrivetTheme.ink,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: _failed
              ? Center(
                  child: Text(
                    'Video unavailable',
                    style: TextStyle(color: PrivetTheme.mist, fontSize: 13),
                  ),
                )
              : !_ready
              ? Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _toggle,
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
                          : Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 36,
                                color: PrivetTheme.signal,
                              ),
                            ),
                    ),
                  ),
                )
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: _controller!.value.size.width,
                        height: _controller!.value.size.height,
                        child: VideoPlayer(_controller!),
                      ),
                    ),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _toggle,
                        child: AnimatedOpacity(
                          opacity: _playing ? 0 : 1,
                          duration: const Duration(milliseconds: 160),
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 36,
                              color: PrivetTheme.signal,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 6,
                      child: VideoProgressIndicator(
                        _controller!,
                        allowScrubbing: true,
                        colors: VideoProgressColors(
                          playedColor: PrivetTheme.signal,
                          bufferedColor: Color(0x55A8E6C3),
                          backgroundColor: Color(0x44FFFFFF),
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
