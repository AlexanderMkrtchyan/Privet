import 'dart:math' as math;
import 'dart:ui' show lerpDouble, Picture;

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
  }) : _path = _buildPath(points);

  final List<Offset> points;

  /// Built once at commit — on web each `Path` op is a JS↔WASM interop call,
  /// so re-building this path on every frame made long strokes stall.
  final Path _path;

  static Path _buildPath(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    return path;
  }

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
    canvas.drawPath(_path, paint);
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

  /// Incrementally grown pencil path — avoids rebuilding the whole path (and
  /// its per-op interop cost on web) on every pointer move.
  Path? _pencilPath;

  /// Returns true when the pencil gained a new point (i.e. something changed).
  bool update(Offset local) {
    end = local;
    if (tool != ImageAnnotTool.pencil) return true;
    final last = points.last;
    if ((local - last).distance < 1.5) return false;
    points.add(local);
    (_pencilPath ??= Path()..moveTo(points.first.dx, points.first.dy))
        .lineTo(local.dx, local.dy);
    return true;
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
    switch (tool) {
      case ImageAnnotTool.pencil:
        final path = _pencilPath;
        if (path == null) return;
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..strokeWidth = strokeWidth
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );
      case ImageAnnotTool.rect:
        final mark = RectMark(
          a: start,
          b: end,
          color: color,
          strokeWidth: strokeWidth,
        );
        mark.paint(canvas);
      case ImageAnnotTool.arrow:
        final mark = ArrowMark(
          a: start,
          b: end,
          color: color,
          strokeWidth: strokeWidth,
        );
        mark.paint(canvas);
    }
  }
}

class ImageAnnotationPainter extends CustomPainter {
  ImageAnnotationPainter({
    required this.marks,
    this.draft,
    this.cachedPicture,
  });

  final List<ImageMark> marks;
  final ImageMarkDraft? draft;

  /// Recorded snapshot of all committed marks, rebuilt only when marks change.
  /// Drawing it each tick avoids re-building (and re-issuing) every stroke's
  /// path per frame — the dominant web jank during drawing.
  final Picture? cachedPicture;

  @override
  void paint(Canvas canvas, Size size) {
    final cached = cachedPicture;
    if (cached != null) {
      canvas.drawPicture(cached);
    } else {
      for (final mark in marks) {
        mark.paint(canvas);
      }
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
