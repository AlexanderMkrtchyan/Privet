import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Diagonal black/yellow caution-tape ring for focused fields and outlines.
class TapeOutlineBorder extends OutlineInputBorder {
  const TapeOutlineBorder({
    super.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.stripeWidth = 7,
    this.bandWidth = 3,
  }) : super(borderSide: const BorderSide(width: 3, color: Colors.transparent));

  final double stripeWidth;
  final double bandWidth;

  static const _black = Color(0xFF111111);
  static const _yellow = Color(0xFFF0D000);

  @override
  TapeOutlineBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) {
    return TapeOutlineBorder(
      borderRadius: borderRadius ?? this.borderRadius,
      stripeWidth: stripeWidth,
      bandWidth: bandWidth,
    );
  }

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is TapeOutlineBorder) return this;
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is TapeOutlineBorder) return this;
    return super.lerpTo(b, t);
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(bandWidth);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    final outer = borderRadius.toRRect(rect);
    final inner = borderRadius.toRRect(rect.deflate(bandWidth));
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(outer)
      ..addRRect(inner);

    canvas.save();
    canvas.clipPath(ring);

    final paint = Paint()..style = PaintingStyle.fill;
    final period = stripeWidth * 2;
    // Cover the rect with -45° bands (caution tape).
    final extent = rect.width + rect.height;
    for (var i = -extent; i < extent; i += period) {
      paint.color = _black;
      final path = Path()
        ..moveTo(rect.left + i, rect.top)
        ..lineTo(rect.left + i + stripeWidth, rect.top)
        ..lineTo(rect.left + i + stripeWidth - rect.height, rect.bottom)
        ..lineTo(rect.left + i - rect.height, rect.bottom)
        ..close();
      canvas.drawPath(path, paint);

      paint.color = _yellow;
      final pathY = Path()
        ..moveTo(rect.left + i + stripeWidth, rect.top)
        ..lineTo(rect.left + i + period, rect.top)
        ..lineTo(rect.left + i + period - rect.height, rect.bottom)
        ..lineTo(rect.left + i + stripeWidth - rect.height, rect.bottom)
        ..close();
      canvas.drawPath(pathY, paint);
    }
    canvas.restore();
  }
}

/// Soft larva-gold ring with short outward setae (fluff).
class LarvaOutlineBorder extends OutlineInputBorder {
  const LarvaOutlineBorder({
    super.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.bandWidth = 1.4,
  }) : super(
          borderSide: const BorderSide(width: 1.4, color: Color(0xFFE8D89A)),
        );

  final double bandWidth;

  static const _body = Color(0xFFE8D89A);
  static const _hairs = [
    Color(0xFFF4EBC4),
    Color(0xFFE8D89A),
    Color(0xFFFFF8DC),
    Color(0xFFE6D392),
    Color(0xFFF7F0D4),
    Color(0xFFFFFBE8),
  ];

  @override
  LarvaOutlineBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) {
    return LarvaOutlineBorder(
      borderRadius: borderRadius ?? this.borderRadius,
      bandWidth: bandWidth,
    );
  }

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is LarvaOutlineBorder) return this;
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is LarvaOutlineBorder) return this;
    return super.lerpTo(b, t);
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(bandWidth + 10);

  @override
  bool get isOutline => true;

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    // Soft-halo fluff sits outside the layout rect.
    final rrect = borderRadius.toRRect(rect).deflate(bandWidth / 2);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = bandWidth
      ..color = _body;
    canvas.drawRRect(rrect, ring);

    final hair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const spacing = 1.4;
    const jitter = 1.1;
    const stroke = 0.5;
    final samples = _sampleRRect(rrect, spacing: spacing);
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final j = math.sin(i * 12.9898) * jitter;
      final ca = math.cos(j);
      final sa = math.sin(j);
      var nx = s.nx * ca - s.ny * sa;
      var ny = s.nx * sa + s.ny * ca;
      final nrm = math.sqrt(nx * nx + ny * ny);
      if (nrm == 0) continue;
      nx /= nrm;
      ny /= nrm;
      final pos = Offset(s.pos.dx - nx * 0.6, s.pos.dy - ny * 0.6);
      final len = 3.0 + (i % 7) * ((5.2 - 3.0) / 7);
      final tip = _hairs[i % _hairs.length];
      final base = tip.withValues(alpha: 0.45);
      hair
        ..strokeWidth = stroke * 1.15
        ..color = base;
      canvas.drawLine(
        pos,
        Offset(pos.dx + nx * len * 0.55, pos.dy + ny * len * 0.55),
        hair,
      );
      hair
        ..strokeWidth = stroke * 0.55
        ..color = tip;
      canvas.drawLine(
        Offset(pos.dx + nx * len * 0.4, pos.dy + ny * len * 0.4),
        Offset(pos.dx + nx * len, pos.dy + ny * len),
        hair,
      );
    }
  }

  static List<({Offset pos, double nx, double ny})> _sampleRRect(
    RRect rrect, {
    required double spacing,
  }) {
    final out = <({Offset pos, double nx, double ny})>[];
    void line(Offset a, Offset b, double nx, double ny) {
      final len = (b - a).distance;
      final n = math.max(1, (len / spacing).round());
      for (var i = 0; i < n; i++) {
        final t = i / n;
        out.add((pos: Offset.lerp(a, b, t)!, nx: nx, ny: ny));
      }
    }

    void arc(Offset c, double r, double a0, double a1) {
      final arcLen = (a1 - a0).abs() * r;
      final n = math.max(2, (arcLen / spacing).round());
      for (var i = 0; i < n; i++) {
        final a = a0 + (a1 - a0) * (i / n);
        out.add((
          pos: Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a)),
          nx: math.cos(a),
          ny: math.sin(a),
        ));
      }
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
}

/// Rounded outline used by [OutlinedButton] for special accents.
class AccentOutlinedBorder extends OutlinedBorder {
  const AccentOutlinedBorder({
    required this.style,
    this.radius = 14,
  }) : super(side: BorderSide.none);

  final AccentStyle style;
  final double radius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(
        style == AccentStyle.tape
            ? 3
            : style == AccentStyle.larva
                ? 12
                : 1.5,
      );

  @override
  AccentOutlinedBorder scale(double t) => this;

  @override
  AccentOutlinedBorder copyWith({BorderSide? side}) =>
      AccentOutlinedBorder(style: style, radius: radius);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final r = BorderRadius.circular(radius);
    switch (style) {
      case AccentStyle.tape:
        TapeOutlineBorder(borderRadius: r).paint(canvas, rect);
      case AccentStyle.larva:
        LarvaOutlineBorder(borderRadius: r).paint(canvas, rect);
      case AccentStyle.yellow:
      case AccentStyle.hacker:
      case AccentStyle.solid:
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = style == AccentStyle.hacker ? 1.5 : 2
          ..color = PrivetTheme.signal;
        if (style == AccentStyle.hacker) {
          paint.maskFilter = const MaskFilter.blur(BlurStyle.outer, 2.5);
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect.deflate(1), Radius.circular(radius)),
            paint,
          );
          paint.maskFilter = null;
        }
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.deflate(1), Radius.circular(radius)),
          paint,
        );
    }
  }
}
