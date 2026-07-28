import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

const _path = '/home/alex/Privet/.cursor/debug-32b317.log';
const _sessionId = '32b317';
/// post-fix3: FLUTTER_LINUX_RENDERER=software (OpenGL present path ~20fps).
const _runId = 'post-fix3';

final _logQueue = Queue<String>();
bool _logDraining = false;
IOSink? _sink;

void agentDebugLog({
  required String hypothesisId,
  required String location,
  required String message,
  Map<String, Object?> data = const {},
  String runId = _runId,
}) {
  try {
    final payload = <String, Object?>{
      'sessionId': _sessionId,
      'hypothesisId': hypothesisId,
      'location': location,
      'message': message,
      'data': data,
      'runId': runId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'platform': defaultTargetPlatform.name,
    };
    _logQueue.add('${jsonEncode(payload)}\n');
    _drainLogs();
  } catch (_) {}
}

void _drainLogs() {
  if (_logDraining) return;
  _logDraining = true;
  scheduleMicrotask(() async {
    try {
      _sink ??= File(_path).openWrite(mode: FileMode.append);
      while (_logQueue.isNotEmpty) {
        _sink!.write(_logQueue.removeFirst());
      }
      await _sink!.flush();
    } catch (_) {
      try {
        await _sink?.close();
      } catch (_) {}
      _sink = null;
    } finally {
      _logDraining = false;
      if (_logQueue.isNotEmpty) _drainLogs();
    }
  });
}

/// Install a timings callback that reports jank windows (H1).
void agentDebugInstallFrameProbe() {
  if (_frameProbeInstalled) return;
  _frameProbeInstalled = true;
  SchedulerBinding.instance.addTimingsCallback(_onTimings);
  // Heartbeat every 2s (was 500ms) — enough to detect stalls without IO noise.
  _heartbeat?.cancel();
  _heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final gap = _lastFrameAtMs == 0 ? -1 : now - _lastFrameAtMs;
    agentDebugLog(
      hypothesisId: 'H6',
      location: 'agent_debug_log_io.dart:heartbeat',
      message: 'isolate heartbeat',
      data: {
        'msSinceLastFrame': gap,
        'framesSinceBoot': _framesSinceBoot,
        'ibeamRebuilds': _ibeamRebuilds,
        'hasCall': _hasCall,
        'glSync': Platform.environment['__GL_SYNC_TO_VBLANK'],
        'glMaxFrames': Platform.environment['__GL_MaxFramesAllowed'],
      },
    );
    _ibeamRebuilds = 0;
  });
  // Event-loop lag (H21): 8ms timer; OpenGL present path starves this (~10–40Hz).
  var lastTick = DateTime.now();
  var lagSum = 0, lagMax = 0, lagLate = 0, ticks = 0, over32 = 0;
  var lagStart = DateTime.now();
  Timer.periodic(const Duration(milliseconds: 8), (_) {
    final now = DateTime.now();
    final delta = now.difference(lastTick).inMilliseconds;
    lastTick = now;
    ticks++;
    final lag = delta - 8;
    if (lag > 0) {
      lagSum += lag;
      lagLate++;
      if (lag > lagMax) lagMax = lag;
      if (lag > 32) over32++;
    }
    if (now.difference(lagStart) < const Duration(seconds: 2)) return;
    final ms = now.difference(lagStart).inMilliseconds.clamp(1, 60000);
    agentDebugLog(
      hypothesisId: 'H21',
      location: 'agent_debug_log_io.dart:eventLoop',
      message: 'event loop lag',
      data: {
        'timerHz': double.parse((ticks * 1000 / ms).toStringAsFixed(1)),
        'avgLagMs': lagLate == 0
            ? 0
            : double.parse((lagSum / lagLate).toStringAsFixed(1)),
        'maxLagMs': lagMax,
        'over32ms': over32,
        'linuxRenderer': Platform.environment['FLUTTER_LINUX_RENDERER'],
      },
    );
    lagSum = 0;
    lagMax = 0;
    lagLate = 0;
    ticks = 0;
    over32 = 0;
    lagStart = now;
    lastTick = DateTime.now();
  });
  agentDebugLog(
    hypothesisId: 'H1',
    location: 'agent_debug_log_io.dart:frameProbe',
    message: 'frame probe installed',
    data: {
      'glSync': Platform.environment['__GL_SYNC_TO_VBLANK'],
      'glMaxFrames': Platform.environment['__GL_MaxFramesAllowed'],
      'glThreaded': Platform.environment['__GL_THREADED_OPTIMIZATIONS'],
      'linuxRenderer': Platform.environment['FLUTTER_LINUX_RENDERER'],
    },
  );
}

Timer? _heartbeat;
bool _frameProbeInstalled = false;
int _frames = 0;
int _jank = 0;
int _buildUsSum = 0;
int _rasterUsSum = 0;
int _vsyncUsSum = 0;
int _maxTotalUs = 0;
int _maxVsyncUs = 0;
int _framesSinceBoot = 0;
int _lastFrameAtMs = 0;
int _ibeamRebuilds = 0;
DateTime _windowStart = DateTime.now();

void agentDebugIBeamRebuild() => _ibeamRebuilds++;

void _onTimings(List<FrameTiming> timings) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  for (final t in timings) {
    _frames++;
    _framesSinceBoot++;
    _lastFrameAtMs = nowMs;
    final total = t.totalSpan.inMicroseconds;
    final vsync = t.vsyncOverhead.inMicroseconds;
    _buildUsSum += t.buildDuration.inMicroseconds;
    _rasterUsSum += t.rasterDuration.inMicroseconds;
    _vsyncUsSum += vsync < 0 ? 0 : vsync;
    if (total > _maxTotalUs) _maxTotalUs = total;
    if (vsync > _maxVsyncUs) _maxVsyncUs = vsync;
    if (total > 18000) _jank++;
  }
  final now = DateTime.now();
  if (now.difference(_windowStart) < const Duration(seconds: 2)) return;
  final elapsedMs = now.difference(_windowStart).inMilliseconds.clamp(1, 60000);
  final fps = (_frames * 1000) / elapsedMs;
  agentDebugLog(
    hypothesisId: 'H1',
    location: 'agent_debug_log_io.dart:frameWindow',
    message: 'frame window',
    data: {
      'frames': _frames,
      'jank': _jank,
      'fps': double.parse(fps.toStringAsFixed(1)),
      'avgBuildMs': _frames == 0
          ? 0
          : double.parse(((_buildUsSum / _frames) / 1000).toStringAsFixed(2)),
      'avgRasterMs': _frames == 0
          ? 0
          : double.parse(((_rasterUsSum / _frames) / 1000).toStringAsFixed(2)),
      'avgVsyncMs': _frames == 0
          ? 0
          : double.parse(((_vsyncUsSum / _frames) / 1000).toStringAsFixed(2)),
      'maxVsyncMs': double.parse((_maxVsyncUs / 1000).toStringAsFixed(2)),
      'maxTotalMs': double.parse((_maxTotalUs / 1000).toStringAsFixed(2)),
      'hasCall': _hasCall,
      'notifyBurst': _notifyBurst,
      'ibeamRebuilds': _ibeamRebuilds,
      'linuxRenderer': Platform.environment['FLUTTER_LINUX_RENDERER'],
    },
  );
  _frames = 0;
  _jank = 0;
  _buildUsSum = 0;
  _rasterUsSum = 0;
  _vsyncUsSum = 0;
  _maxTotalUs = 0;
  _maxVsyncUs = 0;
  _notifyBurst = 0;
  _ibeamRebuilds = 0;
  _windowStart = now;
}

bool _hasCall = false;
int _notifyBurst = 0;

void agentDebugSetHasCall(bool v) => _hasCall = v;

void agentDebugCountNotify(String kind) {
  _notifyBurst++;
  if (_notifyBurst == 1 || _notifyBurst % 25 == 0) {
    agentDebugLog(
      hypothesisId: 'H2',
      location: 'agent_debug_log_io.dart:notify',
      message: 'notify',
      data: {'kind': kind, 'burst': _notifyBurst, 'hasCall': _hasCall},
    );
  }
}
