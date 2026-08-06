import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'gpu_capability.dart';

/// Display-rate aware motion tiering.
///
/// The app already auto-cheapens on weak GPUs ([hasCapableGpu] / low-resource
/// mode). This adds the other half of the story: on a capable GPU connected to
/// a genuinely high-refresh display (e.g. 75 Hz) the app enables the
/// smooth-motion tier; everywhere else it keeps the lighter paths so a
/// rasterizer is never asked to animate faster than it can present.
///
/// Where the rate comes from:
/// - Desktop/mobile: [PlatformDispatcher.displays], which the engine fills from
///   the real monitor rate (GDK on Linux, DWM on Windows, Choreographer on
///   Android). The Linux GTK embedder reports e.g. 75.0 for a 75 Hz panel even
///   though its own frame scheduling is still capped at 60 Hz.
/// - Web: browsers don't expose a refresh-rate API, so we estimate it from a
///   short run of `requestAnimationFrame` timings.

/// Display rates at or above this count as "high refresh" for the smooth tier.
const double kSmoothMotionHz = 70.0;

double? _cachedHz;
DateTime? _cachedAt;
Future<double>? _inFlight;

/// Best known refresh rate in Hz (clamped 30..240, defaults to 60).
Future<double> privetDisplayRefreshRate() async {
  final cached = _cachedHz;
  if (cached != null &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < const Duration(minutes: 5)) {
    return cached;
  }
  final pending = _inFlight;
  if (pending != null) return pending;
  final future = _measure().then((value) {
    _cachedHz = value;
    _cachedAt = DateTime.now();
    return value;
  });
  _inFlight = future;
  try {
    return await future;
  } finally {
    _inFlight = null;
  }
}

/// True only when the device can actually show smooth-motion: a capable GPU
/// **and** a display that refreshes at [kSmoothMotionHz] or faster. Weak GPUs
/// and 60 Hz screens fall through to the standard / cheap animation paths.
Future<bool> shouldEnableSmoothMotion() async {
  if (!await hasCapableGpu()) return false;
  return await privetDisplayRefreshRate() >= kSmoothMotionHz;
}

Future<double> _measure() async {
  final displays = PlatformDispatcher.instance.displays;
  if (displays.isNotEmpty) {
    var best = 0.0;
    for (final display in displays) {
      if (display.refreshRate > best) best = display.refreshRate;
    }
    if (best >= 30 && best <= 240) return best;
  }
  if (kIsWeb) {
    final estimated = await _measureWebRate();
    if (estimated != null) return estimated;
  }
  return 60.0;
}

/// Browser fallback: estimate the display rate from a short rAF run.
Future<double?> _measureWebRate() async {
  final binding = SchedulerBinding.instance;
  final deltas = <double>[];
  final done = Completer<void>();
  DateTime? last;
  void sample(Duration _) {
    final now = DateTime.now();
    if (last != null) {
      final delta = now.difference(last!).inMicroseconds / 1000.0;
      if (delta >= 4 && delta <= 40) deltas.add(delta);
    }
    last = now;
    if (deltas.length >= 24) {
      done.complete();
    } else {
      binding.scheduleFrameCallback(sample);
    }
  }

  binding.scheduleFrameCallback(sample);
  try {
    await done.future.timeout(const Duration(seconds: 2));
  } catch (_) {}
  if (deltas.length < 8) return null;
  deltas.sort();
  final rate = 1000.0 / deltas[deltas.length ~/ 2];
  if (rate >= 30 && rate <= 240) return rate;
  return null;
}
