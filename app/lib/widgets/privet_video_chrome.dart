import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';
import '../util/privet_video_prefs.dart';
import '../util/video_clock.dart';

/// Play / seek / time / volume / speed / fullscreen bar shared by the inline
/// bubble and the fullscreen viewer. Isolated from [VideoPlayer] so scrub
/// ticks never rebuild the texture.
class PrivetVideoChrome extends StatefulWidget {
  const PrivetVideoChrome({
    super.key,
    required this.controller,
    required this.dense,
    required this.playing,
    required this.onPlayPause,
    required this.onToggleFullscreen,
    this.showSpeed = false,
    this.showSkip = false,
    this.onSkip,
  });

  final VideoPlayerController controller;
  final bool dense;
  final bool playing;
  final VoidCallback onPlayPause;
  final VoidCallback onToggleFullscreen;
  final bool showSpeed;
  final bool showSkip;
  final void Function(Duration delta)? onSkip;

  @override
  State<PrivetVideoChrome> createState() => _PrivetVideoChromeState();
}

class _PrivetVideoChromeState extends State<PrivetVideoChrome> {
  Future<void> _toggleMute() async {
    PrivetVideoPrefs.muted = !PrivetVideoPrefs.muted;
    await widget.controller.setVolume(PrivetVideoPrefs.effectiveVolume);
    if (mounted) setState(() {});
  }

  Future<void> _cycleSpeed() async {
    PrivetVideoPrefs.speed = nextPrivetVideoSpeed(PrivetVideoPrefs.speed);
    await widget.controller.setPlaybackSpeed(PrivetVideoPrefs.speed);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dense = widget.dense;
    final pad = dense
        ? const EdgeInsets.fromLTRB(6, 18, 6, 4)
        : const EdgeInsets.fromLTRB(12, 36, 12, 10);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: dense ? 0.55 : 0.72),
          ],
        ),
      ),
      child: Padding(
        padding: pad,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SeekBar(controller: widget.controller, dense: dense),
            SizedBox(height: dense ? 0 : 4),
            Row(
              children: [
                _ChromeIcon(
                  tooltip: widget.playing ? 'Pause' : 'Play',
                  icon: widget.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onPressed: widget.onPlayPause,
                  dense: dense,
                ),
                if (widget.showSkip && widget.onSkip != null) ...[
                  _ChromeIcon(
                    tooltip: 'Back 10 seconds',
                    icon: Icons.replay_10_rounded,
                    onPressed: () =>
                        widget.onSkip!(const Duration(seconds: -10)),
                    dense: dense,
                  ),
                  _ChromeIcon(
                    tooltip: 'Forward 10 seconds',
                    icon: Icons.forward_10_rounded,
                    onPressed: () =>
                        widget.onSkip!(const Duration(seconds: 10)),
                    dense: dense,
                  ),
                ],
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) {
                    return Text(
                      '${formatVideoClock(value.position)} / ${formatVideoClock(value.duration)}',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: dense ? 10.5 : 12,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    );
                  },
                ),
                const Spacer(),
                if (widget.showSpeed)
                  _SpeedChip(
                    speed: PrivetVideoPrefs.speed,
                    onPressed: _cycleSpeed,
                  ),
                _ChromeIcon(
                  tooltip: PrivetVideoPrefs.muted ? 'Unmute' : 'Mute',
                  icon: PrivetVideoPrefs.muted || PrivetVideoPrefs.volume <= 0
                      ? Icons.volume_off_rounded
                      : PrivetVideoPrefs.volume < 0.4
                          ? Icons.volume_down_rounded
                          : Icons.volume_up_rounded,
                  onPressed: _toggleMute,
                  dense: dense,
                ),
                _ChromeIcon(
                  tooltip: dense ? 'Fullscreen' : 'Exit fullscreen',
                  icon: dense
                      ? Icons.fullscreen_rounded
                      : Icons.fullscreen_exit_rounded,
                  onPressed: widget.onToggleFullscreen,
                  dense: dense,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.controller, required this.dense});

  final VideoPlayerController controller;
  final bool dense;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final durationMs = value.duration.inMilliseconds;
        final pos = durationMs <= 0
            ? 0.0
            : (value.position.inMilliseconds / durationMs).clamp(0.0, 1.0);
        final shown = _drag ?? pos;
        var buffered = 0.0;
        if (durationMs > 0 && value.buffered.isNotEmpty) {
          buffered = (value.buffered.last.end.inMilliseconds / durationMs)
              .clamp(0.0, 1.0);
        }
        return SliderTheme(
          data: SliderTheme.of(context).copyWith(
            padding: EdgeInsets.zero,
            trackHeight: widget.dense ? 2.5 : 3.5,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: widget.dense ? 5 : 7,
            ),
            overlayShape: RoundSliderOverlayShape(
              overlayRadius: widget.dense ? 10 : 14,
            ),
            activeTrackColor: PrivetTheme.signal,
            inactiveTrackColor: Colors.white24,
            secondaryActiveTrackColor: Colors.white38,
            thumbColor: Colors.white,
            overlayColor: PrivetTheme.signal.withValues(alpha: 0.22),
          ),
          child: SizedBox(
            height: widget.dense ? 18 : 28,
            child: Slider(
              value: shown,
              secondaryTrackValue: buffered,
              onChanged: durationMs <= 0
                  ? null
                  : (next) => setState(() => _drag = next),
              onChangeEnd: durationMs <= 0
                  ? null
                  : (next) async {
                      setState(() => _drag = null);
                      await widget.controller.seekTo(
                        Duration(milliseconds: (next * durationMs).round()),
                      );
                    },
            ),
          ),
        );
      },
    );
  }
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({required this.speed, required this.onPressed});

  final double speed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = speed == 1.0 ? '1×' : '$speed×';
    return Tooltip(
      message: 'Playback speed',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChromeIcon extends StatelessWidget {
  const _ChromeIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.dense,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final size = dense ? 18.0 : 22.0;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: IconButton(
          onPressed: onPressed,
          mouseCursor: SystemMouseCursors.click,
          icon: Icon(icon, color: Colors.white, size: size),
          iconSize: size,
          padding: EdgeInsets.all(dense ? 4 : 6),
          constraints: BoxConstraints(
            minWidth: dense ? 28 : 36,
            minHeight: dense ? 28 : 36,
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
