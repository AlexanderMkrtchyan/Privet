import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../theme.dart';

/// Lines longer than this get long larva whiskers + pointer wind.
const double kAccentLongLinePx = 300;

/// Soft-halo G: one layer + taper (light).
const double _kLarvaSpacing = 1.4;
const double _kLarvaHairMin = 6.0;
const double _kLarvaHairMax = 11.0;
const double _kLarvaStroke = 0.5;
const double _kLarvaJitter = 1.1;

/// Traveling wave packet along a long larva edge.
const double _kWaveWidthPx = 45;
const double _kWaveSpeedPx = 220; // px / second
const double _kWaveSigma = _kWaveWidthPx / 2.6;
const int _kMaxWaves = 4;

bool _isSpecial(AccentStyle style) =>
    style == AccentStyle.tape || style == AccentStyle.larva;

class _LarvaWave {
  _LarvaWave({required this.originAlong, required this.t0Ms});
  final double originAlong;
  final double t0Ms;
}

/// Shared wave clock — notifies painters without rebuilding widgets.
class _LarvaAnim extends ChangeNotifier {
  final List<_LarvaWave> waves = [];
  double timeMs = 0;
  double? lastSpawnAlong;
  double lastSpawnMs = -1e9;

  bool get active => waves.isNotEmpty;

  void tick(Duration elapsed) {
    timeMs = elapsed.inMilliseconds.toDouble();
    waves.removeWhere((w) => timeMs - w.t0Ms > 3000);
    notifyListeners();
  }

  void spawn(double along) {
    final t0 = timeMs;
    if (lastSpawnAlong != null &&
        (along - lastSpawnAlong!).abs() < 10 &&
        t0 - lastSpawnMs < 90) {
      return;
    }
    waves.add(_LarvaWave(originAlong: along, t0Ms: t0));
    if (waves.length > _kMaxWaves) waves.removeAt(0);
    lastSpawnAlong = along;
    lastSpawnMs = t0;
    notifyListeners();
  }

  void clearSpawnMark() {
    lastSpawnAlong = null;
  }

  void reset() {
    waves.clear();
    lastSpawnAlong = null;
    timeMs = 0;
    notifyListeners();
  }
}

double _larvaWaveAmp(double along, List<_LarvaWave> waves, double nowMs) {
  if (waves.isEmpty) return 0;
  var best = 0.0;
  for (final w in waves) {
    final t = (nowMs - w.t0Ms) / 1000.0;
    if (t < 0 || t > 2.8) continue;
    final front = _kWaveSpeedPx * t;
    final x = (along - w.originAlong).abs() - front;
    // Cheap reject outside ~2σ of the moving front.
    if (x.abs() > _kWaveWidthPx) continue;
    final g = math.exp(-(x * x) / (2 * _kWaveSigma * _kWaveSigma));
    final shim = math.sin(x * 0.22 - t * 14);
    best = math.max(best, g * (0.85 + 0.15 * shim));
  }
  return best;
}

double _hairLen(int i, {required bool long}) {
  final lo = long ? _kLarvaHairMin : 3.0;
  final hi = long ? _kLarvaHairMax : 5.2;
  return lo + (i % 7) * ((hi - lo) / 7);
}

Color _larvaHairColor(int i, double amp, {double alphaScale = 1}) {
  final base = _larvaHairs[i % _larvaHairs.length];
  final a = (1.0 - math.min(0.48, amp * 0.55)) * alphaScale;
  return base.withValues(alpha: a);
}

/// Soft-halo G stroke: thick base + thin tip (one layer).
void _drawSoftHair(
  Canvas canvas,
  Paint hair, {
  required Offset pos,
  required double nx,
  required double ny,
  required double L,
  required double stroke,
  required Color color,
  required Color baseColor,
  required bool taper,
}) {
  if (!taper) {
    hair
      ..strokeWidth = stroke
      ..color = color;
    canvas.drawLine(
      pos,
      Offset(pos.dx + nx * L, pos.dy + ny * L),
      hair,
    );
    return;
  }
  hair
    ..strokeWidth = stroke * 1.15
    ..color = baseColor;
  canvas.drawLine(
    pos,
    Offset(pos.dx + nx * L * 0.55, pos.dy + ny * L * 0.55),
    hair,
  );
  hair
    ..strokeWidth = stroke * 0.55
    ..color = color;
  canvas.drawLine(
    Offset(pos.dx + nx * L * 0.4, pos.dy + ny * L * 0.4),
    Offset(pos.dx + nx * L, pos.dy + ny * L),
    hair,
  );
}

const _larvaBody = Color(0xFFE8D89A);
const _larvaHairs = [
  Color(0xFFF4EBC4),
  Color(0xFFE8D89A),
  Color(0xFFFFF8DC),
  Color(0xFFE6D392),
  Color(0xFFF7F0D4),
  Color(0xFFFFFBE8),
];


/// Inbox↔chat splitter or header↔body rule with tape / larva treatment.
///
/// Rebuilds from [PrivetTheme.revision] so accent switches never leave a
/// stale green/tape/larva paint until the pointer moves.
class AccentSplitLine extends StatelessWidget {
  const AccentSplitLine({
    super.key,
    required this.axis,
    this.thickness = 8,
  });

  final Axis axis;

  /// Cross-axis size for tape stripes (larva uses a wider fluff gutter).
  final double thickness;

  /// Soft-halo G whiskers (L≈11 + wave) need room on both sides.
  static const double larvaGutter = 30;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: PrivetTheme.revision,
      builder: (context, rev, _) {
        final style = PrivetTheme.accentStyle;
        final line = PrivetTheme.line;
        if (!_isSpecial(style)) {
          return axis == Axis.vertical
              ? Container(width: 1, color: line)
              : Container(height: 1, color: line);
        }
        // Soft-halo L≈12 (+ wave stretch) needs a wide gutter on both sides.
        final band =
            style == AccentStyle.larva ? larvaGutter : thickness;
        return SizedBox(
          width: axis == Axis.vertical ? band : null,
          height: axis == Axis.horizontal ? band : null,
          child: _AccentLinePaint(
            key: ValueKey('split-$rev-${style.name}-${axis.name}'),
            axis: axis,
            style: style,
          ),
        );
      },
    );
  }
}

class _AccentLinePaint extends StatefulWidget {
  const _AccentLinePaint({
    super.key,
    required this.axis,
    required this.style,
  });

  final Axis axis;
  final AccentStyle style;

  @override
  State<_AccentLinePaint> createState() => _AccentLinePaintState();
}

class _AccentLinePaintState extends State<_AccentLinePaint>
    with SingleTickerProviderStateMixin {
  final _LarvaAnim _anim = _LarvaAnim();
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _anim.tick(elapsed);
      if (!_anim.active) _ticker.stop();
    });
  }

  @override
  void didUpdateWidget(covariant _AccentLinePaint old) {
    super.didUpdateWidget(old);
    if (old.style != widget.style) {
      _anim.reset();
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _spawnAlong(double along) {
    if (!_ticker.isActive) {
      _anim.timeMs = 0;
      _ticker.start();
    }
    _anim.spawn(along);
  }

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(
      painter: _SplitLinePainter(
        style: widget.style,
        axis: widget.axis,
        anim: _anim,
      ),
      child: const SizedBox.expand(),
    );

    if (widget.style != AccentStyle.larva) {
      return ClipRect(child: paint);
    }

    return MouseRegion(
      onHover: (e) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        final local = box.globalToLocal(e.position);
        final along = widget.axis == Axis.vertical ? local.dy : local.dx;
        _spawnAlong(along);
      },
      onExit: (_) => _anim.clearSpawnMark(),
      child: ClipRect(child: paint),
    );
  }
}

class _SplitLinePainter extends CustomPainter {
  _SplitLinePainter({
    required this.style,
    required this.axis,
    required this.anim,
  }) : super(repaint: anim);

  final AccentStyle style;
  final Axis axis;
  final _LarvaAnim anim;

  static const _black = Color(0xFF111111);
  static const _yellow = Color(0xFFF0D000);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (style == AccentStyle.tape) {
      _paintTape(canvas, rect);
      return;
    }
    if (style == AccentStyle.larva) {
      _paintLarvaLine(canvas, size);
    }
  }

  void _paintTape(Canvas canvas, Rect rect) {
    canvas.save();
    canvas.clipRect(rect);
    final paint = Paint()..style = PaintingStyle.fill;
    const stripe = 7.0;
    final period = stripe * 2;
    final extent = rect.width + rect.height + period * 4;
    for (var i = -extent; i < extent; i += period) {
      paint.color = _black;
      canvas.drawPath(
        Path()
          ..moveTo(rect.left + i, rect.top)
          ..lineTo(rect.left + i + stripe, rect.top)
          ..lineTo(rect.left + i + stripe - rect.height, rect.bottom)
          ..lineTo(rect.left + i - rect.height, rect.bottom)
          ..close(),
        paint,
      );
      paint.color = _yellow;
      canvas.drawPath(
        Path()
          ..moveTo(rect.left + i + stripe, rect.top)
          ..lineTo(rect.left + i + period, rect.top)
          ..lineTo(rect.left + i + period - rect.height, rect.bottom)
          ..lineTo(rect.left + i + stripe - rect.height, rect.bottom)
          ..close(),
        paint,
      );
    }
    canvas.restore();
  }

  void _paintLarvaLine(Canvas canvas, Size size) {
    final core = Paint()..color = _larvaBody;
    if (axis == Axis.vertical) {
      final x = size.width / 2;
      canvas.drawRect(Rect.fromLTWH(x - 1.5, 0, 3, size.height), core);
      _hairsAlong(
        canvas,
        length: size.height,
        origin: Offset(x, 0),
        along: const Offset(0, 1),
        normal: const Offset(1, 0),
      );
    } else {
      final y = size.height / 2;
      canvas.drawRect(Rect.fromLTWH(0, y - 1.5, size.width, 3), core);
      _hairsAlong(
        canvas,
        length: size.width,
        origin: Offset(0, y),
        along: const Offset(1, 0),
        normal: const Offset(0, 1),
      );
    }
  }

  void _hairsAlong(
    Canvas canvas, {
    required double length,
    required Offset origin,
    required Offset along,
    required Offset normal,
  }) {
    final n = math.max(1, (length / _kLarvaSpacing).round());
    final hair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final waves = anim.waves;
    final timeMs = anim.timeMs;
    final live = waves.isNotEmpty;

    for (var i = 0; i < n; i++) {
      final s = length * (i / n);
      final pos = origin + along * s;
      for (final side in [-1.0, 1.0]) {
        final j = math.sin(i * 12.9898 + side) * _kLarvaJitter;
        var nx = normal.dx * side + along.dx * j;
        var ny = normal.dy * side + along.dy * j;
        final nrm = math.sqrt(nx * nx + ny * ny);
        if (nrm == 0) continue;
        nx /= nrm;
        ny /= nrm;
        var L = _hairLen(i, long: true);
        var amp = 0.0;
        if (live) {
          amp = _larvaWaveAmp(s, waves, timeMs);
          if (amp > 0.02) {
            final tx = -ny;
            final ty = nx;
            nx += tx * amp * 0.95;
            ny += ty * amp * 0.95;
            final n2 = math.sqrt(nx * nx + ny * ny);
            nx /= n2;
            ny /= n2;
            L *= 1 + amp * 0.35;
          }
        }
        final tip = _larvaHairColor(i, amp);
        final base = _larvaHairColor(i, amp, alphaScale: 0.45);
        _drawSoftHair(
          canvas,
          hair,
          pos: pos,
          nx: nx,
          ny: ny,
          L: L,
          stroke: _kLarvaStroke * (1 - amp * 0.22),
          color: tip,
          baseColor: base,
          taper: true,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SplitLinePainter old) =>
      old.style != style || old.axis != axis || old.anim != anim;
}

/// Wraps a control / bubble with tape border or larva fluff.
class AccentChromeFrame extends StatelessWidget {
  const AccentChromeFrame({
    super.key,
    required this.child,
    this.radius = 12,
    this.forceLong,
    this.bandWidth,
  });

  final Widget child;
  final double radius;
  final bool? forceLong;
  final double? bandWidth;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: PrivetTheme.revision,
      builder: (context, rev, _) {
        final style = PrivetTheme.accentStyle;
        if (!_isSpecial(style)) return child;
        return _AccentChromeFrameBody(
          key: ValueKey('frame-$rev-${style.name}'),
          radius: radius,
          forceLong: forceLong,
          bandWidth: bandWidth,
          style: style,
          child: child,
        );
      },
    );
  }
}

class _AccentChromeFrameBody extends StatefulWidget {
  const _AccentChromeFrameBody({
    super.key,
    required this.child,
    required this.radius,
    required this.forceLong,
    required this.bandWidth,
    required this.style,
  });

  final Widget child;
  final double radius;
  final bool? forceLong;
  final double? bandWidth;
  final AccentStyle style;

  @override
  State<_AccentChromeFrameBody> createState() => _AccentChromeFrameBodyState();
}

class _AccentChromeFrameBodyState extends State<_AccentChromeFrameBody>
    with SingleTickerProviderStateMixin {
  final _LarvaAnim _anim = _LarvaAnim();
  late final Ticker _ticker;
  Size _size = Size.zero;
  List<({Offset pos, double nx, double ny, double s})> _samples = const [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _anim.tick(elapsed);
      if (!_anim.active) _ticker.stop();
    });
  }

  @override
  void didUpdateWidget(covariant _AccentChromeFrameBody old) {
    super.didUpdateWidget(old);
    if (old.style != widget.style) {
      _anim.reset();
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _anim.dispose();
    super.dispose();
  }

  bool get _long {
    if (widget.forceLong != null) return widget.forceLong!;
    return math.max(_size.width, _size.height) >= kAccentLongLinePx;
  }

  void _syncSize(Size next) {
    if (next == _size || !next.width.isFinite || !next.height.isFinite) return;
    if (next.width <= 0 || next.height <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || next == _size) return;
      setState(() {
        _size = next;
        _rebuildSamples();
      });
    });
  }

  void _rebuildSamples() {
    if (_size == Size.zero) {
      _samples = const [];
      return;
    }
    final band = widget.bandWidth ?? 1.4;
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & _size).deflate(band / 2),
      Radius.circular(widget.radius),
    );
    // Short controls: slightly sparser (many bubbles on screen).
    final spacing = _long ? _kLarvaSpacing : 1.7;
    _samples = _sampleRRectAlong(rrect, spacing: spacing);
  }

  void _spawnNear(Offset local) {
    if (_samples.isEmpty) return;
    var best = _samples.first;
    var bestD = (best.pos - local).distance;
    for (final s in _samples) {
      final d = (s.pos - local).distance;
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    if (bestD > 18) return;

    if (!_ticker.isActive) {
      _anim.timeMs = 0;
      _ticker.start();
    }
    _anim.spawn(best.s);
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final frame = CustomPaint(
      foregroundPainter: _FrameChromePainter(
        style: style,
        radius: widget.radius,
        long: _long,
        anim: _anim,
        bandWidth: widget.bandWidth ?? (style == AccentStyle.tape ? 3.0 : 1.4),
        samples: _samples,
      ),
      child: _MeasureSize(
        onChange: _syncSize,
        child: widget.child,
      ),
    );

    if (style != AccentStyle.larva) return frame;

    return MouseRegion(
      onHover: (e) {
        if (!_long) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        _spawnNear(box.globalToLocal(e.position));
      },
      onExit: (_) => _anim.clearSpawnMark(),
      child: frame,
    );
  }
}

/// Reports the child's laid-out size (works under unbounded constraints).
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required Widget child})
      : super(child: child);

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasureSize renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final next = child?.size ?? Size.zero;
    if (_last == next) return;
    _last = next;
    onChange(next);
  }
}

class _FrameChromePainter extends CustomPainter {
  _FrameChromePainter({
    required this.style,
    required this.radius,
    required this.long,
    required this.anim,
    required this.bandWidth,
    required this.samples,
  }) : super(repaint: anim);

  final AccentStyle style;
  final double radius;
  final bool long;
  final _LarvaAnim anim;
  final double bandWidth;
  final List<({Offset pos, double nx, double ny, double s})> samples;

  static const _black = Color(0xFF111111);
  static const _yellow = Color(0xFFF0D000);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (style == AccentStyle.tape) {
      _paintTapeRing(canvas, rect);
      return;
    }
    if (style == AccentStyle.larva) {
      _paintLarvaRing(canvas, rect);
    }
  }

  void _paintTapeRing(Canvas canvas, Rect rect) {
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final inner = RRect.fromRectAndRadius(
      rect.deflate(bandWidth),
      Radius.circular(math.max(0, radius - bandWidth)),
    );
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(rrect)
      ..addRRect(inner);
    canvas.save();
    canvas.clipPath(ring);
    final paint = Paint()..style = PaintingStyle.fill;
    const stripe = 7.0;
    final period = stripe * 2;
    final extent = rect.width + rect.height + 40;
    for (var i = -extent; i < extent; i += period) {
      paint.color = _black;
      canvas.drawPath(
        Path()
          ..moveTo(rect.left + i, rect.top)
          ..lineTo(rect.left + i + stripe, rect.top)
          ..lineTo(rect.left + i + stripe - rect.height, rect.bottom)
          ..lineTo(rect.left + i - rect.height, rect.bottom)
          ..close(),
        paint,
      );
      paint.color = _yellow;
      canvas.drawPath(
        Path()
          ..moveTo(rect.left + i + stripe, rect.top)
          ..lineTo(rect.left + i + period, rect.top)
          ..lineTo(rect.left + i + period - rect.height, rect.bottom)
          ..lineTo(rect.left + i + stripe - rect.height, rect.bottom)
          ..close(),
        paint,
      );
    }
    canvas.restore();
  }

  void _paintLarvaRing(Canvas canvas, Rect rect) {
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(bandWidth / 2),
      Radius.circular(radius),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = bandWidth
        ..color = _larvaBody,
    );

    final use = samples.isNotEmpty
        ? samples
        : _sampleRRectAlong(
            rrect,
            spacing: long ? _kLarvaSpacing : 1.7,
          );
    final hair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final waves = anim.waves;
    final timeMs = anim.timeMs;
    final live = long && waves.isNotEmpty;
    // Short bubbles: single stroke (no taper) — many on screen at once.
    final taper = long;

    for (var i = 0; i < use.length; i++) {
      final s = use[i];
      final j = math.sin(i * 12.9898) * _kLarvaJitter;
      final ca = math.cos(j);
      final sa = math.sin(j);
      var nx = s.nx * ca - s.ny * sa;
      var ny = s.nx * sa + s.ny * ca;
      final nrm = math.sqrt(nx * nx + ny * ny);
      if (nrm == 0) continue;
      nx /= nrm;
      ny /= nrm;
      var L = _hairLen(i, long: long);
      var amp = 0.0;
      if (live) {
        amp = _larvaWaveAmp(s.s, waves, timeMs);
        if (amp > 0.02) {
          final tx = -ny;
          final ty = nx;
          nx += tx * amp * 0.95;
          ny += ty * amp * 0.95;
          final n2 = math.sqrt(nx * nx + ny * ny);
          nx /= n2;
          ny /= n2;
          L *= 1 + amp * 0.35;
        }
      }
      final tip = _larvaHairColor(i, amp);
      final base = _larvaHairColor(i, amp, alphaScale: 0.45);
      _drawSoftHair(
        canvas,
        hair,
        pos: s.pos,
        nx: nx,
        ny: ny,
        L: L,
        stroke: _kLarvaStroke * (1 - amp * 0.22),
        color: tip,
        baseColor: base,
        taper: taper,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FrameChromePainter old) =>
      old.style != style ||
      old.long != long ||
      old.radius != radius ||
      old.bandWidth != bandWidth ||
      old.anim != anim ||
      old.samples.length != samples.length;
}

List<({Offset pos, double nx, double ny, double s})> _sampleRRectAlong(
  RRect rrect, {
  required double spacing,
}) {
  final out = <({Offset pos, double nx, double ny, double s})>[];
  var along = 0.0;

  void line(Offset a, Offset b, double nx, double ny) {
    final len = (b - a).distance;
    final n = math.max(1, (len / spacing).round());
    for (var i = 0; i < n; i++) {
      final t = i / n;
      out.add((
        pos: Offset.lerp(a, b, t)!,
        nx: nx,
        ny: ny,
        s: along + len * t,
      ));
    }
    along += len;
  }

  void arc(Offset c, double r, double a0, double a1) {
    if (r <= 0) return;
    final arcLen = (a1 - a0).abs() * r;
    final n = math.max(2, (arcLen / spacing).round());
    for (var i = 0; i < n; i++) {
      final a = a0 + (a1 - a0) * (i / n);
      out.add((
        pos: Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a)),
        nx: math.cos(a),
        ny: math.sin(a),
        s: along + arcLen * (i / n),
      ));
    }
    along += arcLen;
  }

  final left = rrect.left;
  final top = rrect.top;
  final right = rrect.right;
  final bottom = rrect.bottom;
  final tl = rrect.tlRadiusX;
  final tr = rrect.trRadiusX;
  final br = rrect.brRadiusX;
  final bl = rrect.blRadiusX;

  line(Offset(left + tl, top), Offset(right - tr, top), 0, -1);
  arc(Offset(right - tr, top + tr), tr, -math.pi / 2, 0);
  line(Offset(right, top + tr), Offset(right, bottom - br), 1, 0);
  arc(Offset(right - br, bottom - br), br, 0, math.pi / 2);
  line(Offset(right - br, bottom), Offset(left + bl, bottom), 0, 1);
  arc(Offset(left + bl, bottom - bl), bl, math.pi / 2, math.pi);
  line(Offset(left, bottom - bl), Offset(left, top + tl), -1, 0);
  arc(Offset(left + tl, top + tl), tl, math.pi, math.pi * 1.5);
  return out;
}

