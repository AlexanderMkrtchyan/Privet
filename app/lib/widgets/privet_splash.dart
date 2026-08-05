import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Smooth, wave-like ink splash used for Privet's press feedback.
///
/// The stock Material splashes ([InkSplash]) paint a solid disk that expands
/// over ~225 ms and snaps out. That reads as abrupt on desktop. This splash
/// instead:
///
///  * blooms a small soft dot out of the pointer instantly for press feedback,
///  * expands a thin leading ring to the edge of the well with an ease-out
///    curve (fast start, long smooth deceleration tail),
///  * leaves a faint trailing fill so the wave reads as a glow rather than a
///    hard stroke, and
///  * dissolves through a continuous opacity ramp on release.
///
/// Painting stays on the owning [Material]'s ink layer, so a ripple never
/// forces the surrounding list, text, or avatars to repaint.
class PrivetSplash extends InteractiveInkFeature {
  /// Begin a wave, centered at [position] relative to [referenceBox].
  ///
  /// See [InkRipple] for the meaning of [containedInkWell], [rectCallback],
  /// and [borderRadius]. In practice this is created through
  /// [PrivetSplash.splashFactory] by [InkWell] / [InkResponse].
  PrivetSplash({
    required super.controller,
    required super.referenceBox,
    required Offset position,
    required super.color,
    required this._textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    super.customBorder,
    double? radius,
    super.onRemoved,
  })  : _position = position,
        _borderRadius = borderRadius ?? BorderRadius.zero,
        _targetRadius = radius ??
            _getTargetRadius(referenceBox, containedInkWell, rectCallback, position),
        _clipCallback = _getClipCallback(referenceBox, containedInkWell, rectCallback) {
    // Press feedback: a small dot blooms from the pointer immediately.
    _fadeInController = AnimationController(
      duration: _pressFadeIn,
      vsync: controller.vsync,
    )
      ..addListener(controller.markNeedsPaint)
      ..forward();
    _fadeIn = _fadeInController.drive(CurveTween(curve: Curves.easeOut));

    // Radius travels from the pointer to the well edge. It starts expanding on
    // press and keeps going (at the wave's pace) once the tap is confirmed.
    _radiusController = AnimationController(
      duration: _pressExpand,
      vsync: controller.vsync,
    )
      ..addListener(controller.markNeedsPaint)
      ..forward();
    _radius = _radiusController.drive(
      Tween<double>(begin: _targetRadius * 0.06, end: _targetRadius * 1.08)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
    );

    // The dissolve tail, started on confirm / cancel.
    _fadeOutController = AnimationController(
      duration: _waveDuration,
      vsync: controller.vsync,
    )
      ..addListener(controller.markNeedsPaint)
      ..addStatusListener(_handleAlphaStatusChanged);
    _fadeOut = _fadeOutController.drive(CurveTween(curve: Curves.easeOutCubic));

    controller.addInkFeature(this);
  }

  static const Duration _pressFadeIn = Duration(milliseconds: 90);
  static const Duration _pressExpand = Duration(milliseconds: 180);
  static const Duration _waveDuration = Duration(milliseconds: 480);
  static const Duration _cancelDuration = Duration(milliseconds: 160);

  final Offset _position;
  final BorderRadius _borderRadius;
  final double _targetRadius;
  final RectCallback? _clipCallback;
  final TextDirection _textDirection;

  late final Animation<double> _fadeIn;
  late final AnimationController _fadeInController;
  late final Animation<double> _fadeOut;
  late final AnimationController _fadeOutController;
  late final Animation<double> _radius;
  late final AnimationController _radiusController;

  /// Used to specify this type of ink splash for an [InkWell], [InkResponse],
  /// the material [Theme], or a [ButtonStyle].
  static const InteractiveInkFeatureFactory splashFactory = _PrivetSplashFactory();

  @override
  void confirm() {
    // Let the wave keep expanding at its own (longer) pace, then dissolve.
    _radiusController.duration = _waveDuration;
    _radiusController.forward();
    _fadeInController.forward();
    _fadeOutController.animateTo(1.0, duration: _waveDuration);
  }

  @override
  void cancel() {
    _fadeInController.stop();
    _fadeOutController.animateTo(1.0, duration: _cancelDuration);
  }

  void _handleAlphaStatusChanged(AnimationStatus status) {
    if (status.isCompleted) {
      dispose();
    }
  }

  @override
  void dispose() {
    _radiusController.dispose();
    _fadeInController.dispose();
    _fadeOutController.dispose();
    super.dispose();
  }

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    final double t = _radiusController.value;
    final Rect? rect = _clipCallback?.call();
    // The wave migrates toward the well center as it grows so it fills the
    // whole item instead of staying pinned under the cursor.
    final Offset center = Offset.lerp(
      _position,
      rect != null ? rect.center : referenceBox.size.center(Offset.zero),
      Curves.easeOutCubic.transform(t),
    )!;
    final double radius = _radius.value;

    // Continuous opacity: blooms on press (fadeIn), then dissolves on
    // confirm/cancel (fadeOut). `1 - fadeOut` keeps the value seamless at the
    // handoff between the two phases.
    final double opacity = (1.0 - _fadeOut.value) *
        (_fadeInController.isAnimating ? _fadeIn.value : 1.0);
    final double ringAlpha = color.a * opacity;
    final double fillAlpha = color.a * opacity * 0.28;

    final Paint ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4 - (1.6 * t)
      ..color = color.withValues(alpha: ringAlpha);
    final Paint fillPaint = Paint()..color = color.withValues(alpha: fillAlpha);

    final Offset? originOffset = MatrixUtils.getAsTranslation(transform);
    canvas.save();
    if (originOffset == null) {
      canvas.transform(transform.storage);
    } else {
      canvas.translate(originOffset.dx, originOffset.dy);
    }
    if (_clipCallback != null) {
      final Rect clip = _clipCallback();
      final ShapeBorder? border = customBorder;
      if (border != null) {
        canvas.clipPath(border.getOuterPath(clip, textDirection: _textDirection));
      } else if (_borderRadius != BorderRadius.zero) {
        canvas.clipRRect(
          RRect.fromRectAndCorners(
            clip,
            topLeft: _borderRadius.topLeft,
            topRight: _borderRadius.topRight,
            bottomLeft: _borderRadius.bottomLeft,
            bottomRight: _borderRadius.bottomRight,
          ),
        );
      } else {
        canvas.clipRect(clip);
      }
    }
    canvas.drawCircle(center, radius, ringPaint);
    canvas.drawCircle(center, math.max(1.0, radius * 0.52), fillPaint);
    canvas.restore();
  }
}

class _PrivetSplashFactory extends InteractiveInkFeatureFactory {
  const _PrivetSplashFactory();

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    return PrivetSplash(
      controller: controller,
      referenceBox: referenceBox,
      position: position,
      color: color,
      containedInkWell: containedInkWell,
      rectCallback: rectCallback,
      borderRadius: borderRadius,
      customBorder: customBorder,
      radius: radius,
      onRemoved: onRemoved,
      textDirection: textDirection,
    );
  }
}

RectCallback? _getClipCallback(
  RenderBox referenceBox,
  bool containedInkWell,
  RectCallback? rectCallback,
) {
  if (rectCallback != null) {
    assert(containedInkWell);
    return rectCallback;
  }
  if (containedInkWell) {
    return () => Offset.zero & referenceBox.size;
  }
  return null;
}

double _getTargetRadius(
  RenderBox referenceBox,
  bool containedInkWell,
  RectCallback? rectCallback,
  Offset position,
) {
  final Size size = rectCallback != null ? rectCallback().size : referenceBox.size;
  final double d1 = size.bottomRight(Offset.zero).distance;
  final double d2 = (size.topRight(Offset.zero) - size.bottomLeft(Offset.zero)).distance;
  return math.max(d1, d2) / 2.0;
}
