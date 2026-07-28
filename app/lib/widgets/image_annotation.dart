import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Markup tools available in the image lightbox.
enum ImageAnnotTool { pencil, rect, arrow }

/// One committed annotation on an image (image-local coordinates).
sealed class ImageMark {
  const ImageMark({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  void paint(Canvas canvas);
}

class FreehandMark extends ImageMark {
  FreehandMark({
    required this.points,
    required super.color,
    required super.strokeWidth,
  });

  final List<Offset> points;

  @override
  void paint(Canvas canvas) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);
  }
}

class RectMark extends ImageMark {
  RectMark({
    required this.a,
    required this.b,
    required super.color,
    required super.strokeWidth,
  });

  final Offset a;
  final Offset b;

  @override
  void paint(Canvas canvas) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter
      ..isAntiAlias = true;
    canvas.drawRect(Rect.fromPoints(a, b), paint);
  }
}

class ArrowMark extends ImageMark {
  ArrowMark({
    required this.a,
    required this.b,
    required super.color,
    required super.strokeWidth,
  });

  final Offset a;
  final Offset b;

  @override
  void paint(Canvas canvas) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawLine(a, b, paint);

    final len = (b - a).distance;
    if (len < 4) return;
    final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
    final head = math.max(14.0, strokeWidth * 4.5);
    final spread = 0.45;
    final p1 = Offset(
      b.dx - head * math.cos(angle - spread),
      b.dy - head * math.sin(angle - spread),
    );
    final p2 = Offset(
      b.dx - head * math.cos(angle + spread),
      b.dy - head * math.sin(angle + spread),
    );
    final headPath = Path()
      ..moveTo(b.dx, b.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(
      headPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }
}

/// In-progress stroke while the pointer is down.
class ImageMarkDraft {
  ImageMarkDraft({
    required this.tool,
    required this.start,
    required this.color,
    required this.strokeWidth,
  }) : points = <Offset>[start],
       end = start;

  final ImageAnnotTool tool;
  final Offset start;
  Offset end;
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  void update(Offset local) {
    end = local;
    if (tool == ImageAnnotTool.pencil) {
      final last = points.last;
      if ((local - last).distance >= 1.5) points.add(local);
    }
  }

  ImageMark? commit() {
    switch (tool) {
      case ImageAnnotTool.pencil:
        if (points.length < 2) return null;
        return FreehandMark(
          points: List<Offset>.from(points),
          color: color,
          strokeWidth: strokeWidth,
        );
      case ImageAnnotTool.rect:
        if ((end - start).distance < 4) return null;
        return RectMark(
          a: start,
          b: end,
          color: color,
          strokeWidth: strokeWidth,
        );
      case ImageAnnotTool.arrow:
        if ((end - start).distance < 4) return null;
        return ArrowMark(
          a: start,
          b: end,
          color: color,
          strokeWidth: strokeWidth,
        );
    }
  }

  void paint(Canvas canvas) {
    final mark = switch (tool) {
      ImageAnnotTool.pencil => FreehandMark(
          points: points,
          color: color,
          strokeWidth: strokeWidth,
        ),
      ImageAnnotTool.rect => RectMark(
          a: start,
          b: end,
          color: color,
          strokeWidth: strokeWidth,
        ),
      ImageAnnotTool.arrow => ArrowMark(
          a: start,
          b: end,
          color: color,
          strokeWidth: strokeWidth,
        ),
    };
    mark.paint(canvas);
  }
}

class ImageAnnotationPainter extends CustomPainter {
  ImageAnnotationPainter({
    required this.marks,
    this.draft,
  });

  final List<ImageMark> marks;
  final ImageMarkDraft? draft;

  @override
  void paint(Canvas canvas, Size size) {
    for (final mark in marks) {
      mark.paint(canvas);
    }
    draft?.paint(canvas);
  }

  @override
  bool shouldRepaint(covariant ImageAnnotationPainter oldDelegate) => true;
}

/// Stroke width scaled lightly to image size so marks stay readable.
double annotationStrokeWidth(Size imageSize) {
  final base = math.min(imageSize.width, imageSize.height);
  return lerpDouble(2.5, 5.5, (base / 1200).clamp(0.0, 1.0)) ?? 3.5;
}

/// Classic markup inks.
const List<Color> kAnnotationInks = <Color>[
  Color(0xFFFF3B30), // red
  Color(0xFFFFCC00), // yellow
  Color(0xFFFFFFFF), // white
  Color(0xFF34C759), // green
];
