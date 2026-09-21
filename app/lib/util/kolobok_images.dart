import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'kolobok_smileys.dart';
import 'kolobok_webp.dart';

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

  /// Fires only when [generation] advances — not on every animation tick.
  /// Use this for list previews that swap Unicode → art without needing
  /// continuous GIF playback.
  final ValueNotifier<int> generationListenable = ValueNotifier(0);

  int _listenerCount = 0;
  bool _ticking = false;
  Timer? _timer;

  /// ~30 fps clock. A Dart [Timer] keeps smileys moving even when Windows
  /// merged-thread / idle vsync stops scheduling frames (caret + typing use
  /// the same approach).
  static const Duration _tickPeriod = Duration(milliseconds: 33);

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
    if (_listenerCount == 0) _stopTicking();
  }

  void _ensureTicking() {
    if (_ticking || _listenerCount == 0) return;
    _ticking = true;
    _timer?.cancel();
    _timer = Timer.periodic(_tickPeriod, (_) {
      if (!_ticking || _listenerCount == 0) {
        _stopTicking();
        return;
      }
      _clockMs += _tickPeriod.inMilliseconds;
      notifyListeners();
    });
  }

  void _stopTicking() {
    _ticking = false;
    _timer?.cancel();
    _timer = null;
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
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final anim = await _decodeBytes(bytes);
      if (anim == null) return;
      _anims[path]?.dispose();
      _anims[path] = anim;
      _generation++;
      generationListenable.value = _generation;
      notifyListeners();
      _ensureTicking();
    } catch (_) {
      // Missing or undecodable asset: leave it uncached so the Unicode glyph
      // keeps rendering instead of leaving a hole in the message.
    }
  }

  /// Native multi-frame codec first; if it only yields a still, split the
  /// animated WebP and decode each ANMF as a still image.
  ///
  /// Windows Impeller / WIC often reports a single frame for lossless VP8L
  /// animation, which is every Kolobok file — Linux Skia decodes them fine.
  Future<_KolobokAnim?> _decodeBytes(Uint8List bytes) async {
    final parsed = parseAnimatedWebp(bytes);
    final native = await _decodeWithEngine(bytes);
    if (native != null &&
        (parsed == null || native.frames.length >= parsed.frames.length)) {
      return native;
    }
    if (parsed != null) {
      final split = await _decodeParsedWebp(parsed);
      if (split != null) {
        native?.dispose();
        return split;
      }
    }
    return native;
  }

  Future<_KolobokAnim?> _decodeWithEngine(Uint8List bytes) async {
    final frames = <ui.Image>[];
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
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
      codec = null;
      if (frames.isEmpty) return null;
      return _KolobokAnim(frames, delays);
    } catch (_) {
      codec?.dispose();
      for (final img in frames) {
        img.dispose();
      }
      return null;
    }
  }

  Future<_KolobokAnim?> _decodeParsedWebp(KolobokWebpAnimation parsed) async {
    final frames = <ui.Image>[];
    final delays = <int>[];
    ui.Image? canvas;
    var prevDispose = false;
    var prevRect = ui.Rect.zero;

    try {
      for (final frame in parsed.frames) {
        final still = await _decodeStill(frame.stillWebp);
        if (still == null) {
          for (final img in frames) {
            img.dispose();
          }
          return null;
        }

        final dest = ui.Rect.fromLTWH(
          frame.offsetX.toDouble(),
          frame.offsetY.toDouble(),
          frame.width.toDouble(),
          frame.height.toDouble(),
        );
        final fullReplace = canvas == null &&
            !prevDispose &&
            !frame.blend &&
            dest.left == 0 &&
            dest.top == 0 &&
            dest.width == parsed.canvasWidth &&
            dest.height == parsed.canvasHeight;

        late final ui.Image displayed;
        if (fullReplace) {
          displayed = still;
        } else {
          displayed = await _compositeFrame(
            previous: canvas,
            still: still,
            canvasWidth: parsed.canvasWidth,
            canvasHeight: parsed.canvasHeight,
            dest: dest,
            blend: frame.blend,
            clearPrevious: prevDispose,
            previousRect: prevRect,
          );
          still.dispose();
        }

        frames.add(displayed);
        delays.add(frame.durationMs <= 0 ? 100 : frame.durationMs);
        canvas = displayed;
        prevDispose = frame.disposeToBackground;
        prevRect = dest;
      }
    } catch (_) {
      for (final img in frames) {
        img.dispose();
      }
      return null;
    }

    if (frames.isEmpty) return null;
    return _KolobokAnim(frames, delays);
  }

  Future<ui.Image?> _decodeStill(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final info = await codec.getNextFrame();
      codec.dispose();
      return info.image;
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image> _compositeFrame({
    required ui.Image? previous,
    required ui.Image still,
    required int canvasWidth,
    required int canvasHeight,
    required ui.Rect dest,
    required bool blend,
    required bool clearPrevious,
    required ui.Rect previousRect,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (previous != null) {
      if (clearPrevious) {
        // Avoid BlendMode.clear — Impeller on Windows often no-ops or faults
        // on it, which aborted the whole multi-frame decode and left smileys
        // stuck on frame 0. Redraw the previous canvas in three strips around
        // the disposed rect instead.
        _drawExceptRect(
          canvas,
          previous,
          canvasWidth.toDouble(),
          canvasHeight.toDouble(),
          previousRect,
        );
      } else {
        canvas.drawImage(previous, ui.Offset.zero, ui.Paint());
      }
    }
    final src = ui.Rect.fromLTWH(
      0,
      0,
      still.width.toDouble(),
      still.height.toDouble(),
    );
    canvas.drawImageRect(
      still,
      src,
      dest,
      ui.Paint()..blendMode = blend ? ui.BlendMode.srcOver : ui.BlendMode.src,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasWidth, canvasHeight);
    picture.dispose();
    return image;
  }

  /// Paints [image] covering the canvas except [hole] (dispose-to-background).
  void _drawExceptRect(
    ui.Canvas canvas,
    ui.Image image,
    double width,
    double height,
    ui.Rect hole,
  ) {
    final paint = ui.Paint();
    final clips = <ui.Rect>[
      ui.Rect.fromLTRB(0, 0, width, hole.top.clamp(0, height)),
      ui.Rect.fromLTRB(0, hole.bottom.clamp(0, height), width, height),
      ui.Rect.fromLTRB(
        0,
        hole.top.clamp(0, height),
        hole.left.clamp(0, width),
        hole.bottom.clamp(0, height),
      ),
      ui.Rect.fromLTRB(
        hole.right.clamp(0, width),
        hole.top.clamp(0, height),
        width,
        hole.bottom.clamp(0, height),
      ),
    ];
    for (final clip in clips) {
      if (clip.width <= 0 || clip.height <= 0) continue;
      canvas.save();
      canvas.clipRect(clip);
      canvas.drawImage(image, ui.Offset.zero, paint);
      canvas.restore();
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
