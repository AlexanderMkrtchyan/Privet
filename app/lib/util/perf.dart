import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Lightweight frame / rebuild diagnostics for profile and debug builds.
///
/// Enable with `--dart-define=PRIVET_PERF=1` or call [PerfDiagnostics.enable].
abstract final class PerfDiagnostics {
  static bool _enabled =
      bool.fromEnvironment('PRIVET_PERF', defaultValue: false);
  static bool _installed = false;
  static int _frames = 0;
  static int _jankFrames = 0;
  static int _buildMarks = 0;
  static DateTime _windowStart = DateTime.now();

  static bool get enabled => _enabled;

  static void enable() {
    _enabled = true;
    _ensureInstalled();
  }

  static void _ensureInstalled() {
    if (!_enabled || _installed) return;
    _installed = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (!_enabled) return;
    for (final t in timings) {
      _frames++;
      final totalUs = t.totalSpan.inMicroseconds;
      // >18ms ≈ missed 60fps; count as jank on low-end targets.
      if (totalUs > 18000) _jankFrames++;
    }
    final now = DateTime.now();
    if (now.difference(_windowStart) >= const Duration(seconds: 5)) {
      debugPrint(
        '[privet-perf] frames=$_frames jank=$_jankFrames '
        'builds=$_buildMarks (last 5s)',
      );
      _frames = 0;
      _jankFrames = 0;
      _buildMarks = 0;
      _windowStart = now;
    }
  }

  /// Count a widget build in a hot path (shell / inbox / message row).
  static void markBuild(String label) {
    if (!_enabled) return;
    _ensureInstalled();
    _buildMarks++;
    assert(() {
      // Verbose only in debug asserts.
      return true;
    }());
  }
}

/// Decode caps for chat thumbnails — avoids full-resolution RAM spikes.
abstract final class ImageDecodeCaps {
  /// Pixel width to ask Flutter to decode into for a displayed [logicalWidth].
  static int cacheWidth(double logicalWidth, {double dpr = 1.0}) {
    final w = (logicalWidth * dpr).round();
    return w.clamp(32, 1280);
  }

  static int cacheHeight(double logicalHeight, {double dpr = 1.0}) {
    final h = (logicalHeight * dpr).round();
    return h.clamp(32, 1280);
  }
}
