import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import '../util/voice_playback_source.dart';

/// Staged voice message waiting to be sent from the composer.
class VoiceDraft {
  const VoiceDraft({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;
}

String formatVoiceDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
}

/// Live recording strip — pulsing mic, level bars, elapsed time, cancel.
class ComposerVoiceRecordingBar extends StatelessWidget {
  const ComposerVoiceRecordingBar({
    super.key,
    required this.elapsed,
    required this.levels,
    required this.onCancel,
    this.embedded = false,
  });

  final Duration elapsed;
  final List<double> levels;
  final VoidCallback onCancel;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return _VoiceComposerShell(
      embedded: embedded,
      child: Row(
        children: [
          _PulsingMic(),
          const SizedBox(width: 10),
          Expanded(
            child: _LevelBars(levels: levels, active: true),
          ),
          const SizedBox(width: 10),
          Text(
            formatVoiceDuration(elapsed),
            style: GoogleFonts.ibmPlexSans(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
              color: PrivetTheme.danger,
            ),
          ),
          IconButton(
            tooltip: 'Cancel recording',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
            color: PrivetTheme.mist,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Staged voice clip — play/pause, scrub bar, duration, discard.
class ComposerVoiceDraftBar extends StatefulWidget {
  const ComposerVoiceDraftBar({
    super.key,
    required this.draft,
    required this.onDiscard,
    this.embedded = false,
  });

  final VoiceDraft draft;
  final VoidCallback onDiscard;
  final bool embedded;

  @override
  State<ComposerVoiceDraftBar> createState() => _ComposerVoiceDraftBarState();
}

class _ComposerVoiceDraftBarState extends State<ComposerVoiceDraftBar> {
  final _player = AudioPlayer();
  Source? _source;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _ready = false;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<void>? _completeSub;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void didUpdateWidget(covariant ComposerVoiceDraftBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draft.bytes != widget.draft.bytes) {
      unawaited(_prepare());
    }
  }

  Future<void> _prepare() async {
    await _stopPlayback();
    final source = await voicePlaybackSource(
      widget.draft.bytes,
      widget.draft.mimeType,
    );
    if (!mounted) {
      disposeVoicePlaybackSource(source);
      return;
    }
    _source = source;
    await _player.setSource(source);
    final duration = await _player.getDuration();
    if (!mounted) return;
    setState(() {
      _duration = duration ?? Duration.zero;
      _position = Duration.zero;
      _ready = true;
    });
  }

  Future<void> _stopPlayback() async {
    await _positionSub?.cancel();
    await _completeSub?.cancel();
    _positionSub = null;
    _completeSub = null;
    await _player.stop();
    disposeVoicePlaybackSource(_source);
    _source = null;
    if (mounted) {
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
    }
  }

  Future<void> _togglePlayback() async {
    if (!_ready || _source == null) return;
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
      return;
    }
    if (_position >= _duration && _duration > Duration.zero) {
      await _player.seek(Duration.zero);
      if (mounted) setState(() => _position = Duration.zero);
    }
    if (_position > Duration.zero) {
      await _player.resume();
    } else {
      await _player.play(_source!);
    }
    if (!mounted) return;
    setState(() => _playing = true);
    await _positionSub?.cancel();
    await _completeSub?.cancel();
    _positionSub = _player.onPositionChanged.listen((next) {
      if (!mounted) return;
      setState(() => _position = next);
    });
    _completeSub = _player.onPlayerComplete.listen((_) async {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _position = _duration;
      });
    });
  }

  Future<void> _seekFraction(double fraction) async {
    if (!_ready || _duration <= Duration.zero) return;
    final target = Duration(
      milliseconds: (_duration.inMilliseconds * fraction).round(),
    );
    await _player.seek(target);
    if (mounted) setState(() => _position = target);
  }

  @override
  void dispose() {
    unawaited(_stopPlayback());
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration > Duration.zero ? _duration : _position;
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    return _VoiceComposerShell(
      embedded: widget.embedded,
      child: Row(
        children: [
          Material(
            color: PrivetTheme.signal.withValues(alpha: 0.14),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _togglePlayback,
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  _playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: PrivetTheme.signal,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: widget.embedded
                ? _PlaybackTrack(
                    progress: progress,
                    active: _playing,
                    onSeek: _seekFraction,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Voice message',
                        style: GoogleFonts.syne(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: PrivetTheme.signal,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _PlaybackTrack(
                        progress: progress,
                        active: _playing,
                        onSeek: _seekFraction,
                      ),
                    ],
                  ),
          ),
          const SizedBox(width: 10),
          Text(
            formatVoiceDuration(_playing || _position > Duration.zero
                ? _position
                : total),
            style: GoogleFonts.ibmPlexSans(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
              color: PrivetTheme.paper,
            ),
          ),
          IconButton(
            tooltip: 'Discard voice message',
            onPressed: widget.onDiscard,
            icon: const Icon(Icons.close_rounded),
            color: PrivetTheme.mist,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _VoiceComposerShell extends StatelessWidget {
  const _VoiceComposerShell({required this.child, this.embedded = false});

  final Widget child;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    if (embedded) {
      return InputDecorator(
        isFocused: false,
        isEmpty: false,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: PrivetTheme.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: PrivetTheme.signal),
          ),
          filled: true,
          fillColor: PrivetTheme.ink.withValues(alpha: 0.35),
        ),
        child: child,
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
      decoration: BoxDecoration(
        color: PrivetTheme.panelElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PrivetTheme.line),
      ),
      child: child,
    );
  }
}

class _PulsingMic extends StatefulWidget {
  @override
  State<_PulsingMic> createState() => _PulsingMicState();
}

class _PulsingMicState extends State<_PulsingMic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: PrivetTheme.danger.withValues(
              alpha: 0.12 + (_pulse.value * 0.18),
            ),
          ),
          child: child,
        );
      },
      child: Icon(Icons.mic_rounded, color: PrivetTheme.danger),
    );
  }
}

class _LevelBars extends StatelessWidget {
  const _LevelBars({required this.levels, required this.active});

  final List<double> levels;
  final bool active;

  @override
  Widget build(BuildContext context) {
    const barCount = 28;
    final samples = List<double>.generate(barCount, (index) {
      if (levels.isEmpty) return active ? 0.12 : 0.08;
      final sourceIndex =
          ((index / barCount) * levels.length).floor().clamp(0, levels.length - 1);
      return levels[sourceIndex].clamp(0.08, 1.0);
    });

    return RepaintBoundary(
      child: SizedBox(
        height: 28,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final level in samples) ...[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    height: 6 + (level * 18),
                    decoration: BoxDecoration(
                      color: active
                          ? PrivetTheme.danger
                              .withValues(alpha: 0.35 + level * 0.55)
                          : PrivetTheme.signal
                              .withValues(alpha: 0.25 + level * 0.55),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlaybackTrack extends StatelessWidget {
  const _PlaybackTrack({
    required this.progress,
    required this.active,
    required this.onSeek,
  });

  final double progress;
  final bool active;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final fraction = (details.localPosition.dx / constraints.maxWidth)
                .clamp(0.0, 1.0);
            onSeek(fraction);
          },
          onHorizontalDragUpdate: (details) {
            final fraction = (details.localPosition.dx / constraints.maxWidth)
                .clamp(0.0, 1.0);
            onSeek(fraction);
          },
          child: SizedBox(
            height: 24,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: PrivetTheme.line,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: progress.clamp(0.0, 1.0),
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: active ? PrivetTheme.signal : PrivetTheme.mist,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment(progress * 2 - 1, 0),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: PrivetTheme.signal,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: PrivetTheme.signal.withValues(alpha: 0.35),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
