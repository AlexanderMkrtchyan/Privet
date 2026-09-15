import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Soft white radial disc behind Kolobok art on dark UI so black outlines/hair
/// stay readable. Center is bright white; edges dissolve into transparency.
void paintKolobokHalo(
  Canvas canvas,
  Offset center,
  double diameter, {
  double peakOpacity = 0.9,
}) {
  if (PrivetTheme.isLight) return;
  final radius = diameter * 0.72;
  final paint = Paint()
    ..shader = ui.Gradient.radial(
      center,
      radius,
      [
        Color.fromRGBO(255, 255, 255, peakOpacity),
        Color.fromRGBO(255, 255, 255, peakOpacity * 0.4),
        const Color.fromRGBO(255, 255, 255, 0),
      ],
      const [0.0, 0.42, 1.0],
    );
  canvas.drawCircle(center, radius, paint);
}
