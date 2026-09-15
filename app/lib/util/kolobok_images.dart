import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'kolobok_smileys.dart';

class _KolobokAnim {
  _KolobokAnim(this.frames, this.delaysMs)
      : totalMs = delaysMs.fold<int>(0, (sum, d) => sum + d);

  final List<ui.Image> frames;
  final List<int> delaysMs;
  final int totalMs;

  ui.Image frameAt(int clockMs) {
    if (frames.length == 1 || totalMs <= 0) return frames.first;
    var t = clockMs % totalMs;
    for (var i = 0; i < frames.length; i++) {
      t -= delaysMs[i];
      if (t < 0) return frames[i];
    }
    return frames.last;
  }

  void dispose() {
    for (final frame in frames) {
      frame.dispose();
    }
  }
}

/// Decoded Kolobok GIF animations, keyed by asset path.
///
/// Message bodies are painted by a [TextPainter] inside a `CustomPaint` — there
/// is no widget layer to host an `Image`, so the painter draws the bitmap
/// itself and needs a [ui.Image] rather than asset bytes.
///
/// Every frame of the GIF is kept, and a shared ticker advances [clockMs] so
/// inline smileys and the [KolobokSmiley] widget stay in sync. Listeners are
/// notified on every tick while at least one surface is watching; the ticker
/// stops when the last listener leaves, so idle chats cost nothing.
///
/// The light and dark packs are separate artwork, so the path — and therefore
/// the cache entry — differs per brightness.
class KolobokImageCache extends ChangeNotifier {
  KolobokImageCache._();

  static final KolobokImageCache instance = KolobokImageCache._();

  final Map<String, _KolobokAnim> _anims = {};
  final Set<String> _requested = {};

  /// Monotonic clock used to pick the current GIF frame. Advances while the
  /// ticker is running.
  int get clockMs => _clockMs;
  int _clockMs = 0;

  /// Bumped whenever a GIF finishes decoding, so callers can invalidate
  /// layout that was built while the frames were still missing.
  int get generation => _generation;
  int _generation = 0;

  int _listenerCount = 0;
  bool _ticking = false;
  Duration _lastTick = Duration.zero;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount++;
    _ensureTicking();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listenerCount = (_listenerCount - 1).clamp(0, 1 << 30);
    if (_listenerCount == 0) _ticking = false;
  }

  void _ensureTicking() {
    if (_ticking || _listenerCount == 0) return;
    _ticking = true;
    _lastTick = Duration.zero;
    SchedulerBinding.instance.scheduleFrameCallback(_onTick);
  }

  void _onTick(Duration timestamp) {
    if (!_ticking || _listenerCount == 0) {
      _ticking = false;
      return;
    }
    if (_lastTick != Duration.zero) {
      final delta = timestamp - _lastTick;
      // Cap a hitch so a long pause does not jump the animation.
      final ms = delta.inMilliseconds.clamp(0, 50);
      if (ms > 0) {
        _clockMs += ms;
        notifyListeners();
      }
    }
    _lastTick = timestamp;
    SchedulerBinding.instance.scheduleFrameCallback(_onTick);
  }

  /// The frame that should be painted right now, or null while decoding.
  ///
  /// A null return schedules the decode; [generation] advances when it lands.
  /// Pass [animate]: false to always take frame 0 (reaction chips, low-resource).
  ui.Image? frameFor(String file, {required bool light, bool animate = true}) {
    final path = kolobokAssetPath(file, light: light);
    final anim = _anims[path];
    if (anim != null) {
      return animate ? anim.frameAt(_clockMs) : anim.frames.first;
    }
    if (_requested.add(path)) unawaited(_decode(path));
    return null;
  }

  /// Whether [file] can be painted right now — callers use this to decide
  /// whether hiding the underlying glyph is safe.
  bool isReady(String file, {required bool light}) =>
      _anims.containsKey(kolobokAssetPath(file, light: light));

  Future<void> _decode(String path) async {
    try {
      final data = await rootBundle.load(path);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frames = <ui.Image>[];
      final delays = <int>[];
      for (var i = 0; i < codec.frameCount; i++) {
        final info = await codec.getNextFrame();
        frames.add(info.image);
        // GIFs sometimes report 0ms; treat that as the classic 100ms default
        // so the animation still advances.
        final ms = info.duration.inMilliseconds;
        delays.add(ms <= 0 ? 100 : ms);
      }
      codec.dispose();
      if (frames.isEmpty) return;
      _anims[path]?.dispose();
      _anims[path] = _KolobokAnim(frames, delays);
      _generation++;
      notifyListeners();
      _ensureTicking();
    } catch (_) {
      // Missing or undecodable asset: leave it uncached so the Unicode glyph
      // keeps rendering instead of leaving a hole in the message.
    }
  }

  /// Warms [files] so the first paint of a chat already has its art.
  void preload(Iterable<String> files, {required bool light}) {
    for (final file in files) {
      frameFor(file, light: light);
    }
  }

  @override
  void dispose() {
    _ticking = false;
    for (final anim in _anims.values) {
      anim.dispose();
    }
    _anims.clear();
    super.dispose();
  }
}
