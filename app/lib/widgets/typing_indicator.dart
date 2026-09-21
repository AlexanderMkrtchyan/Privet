import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/low_resource.dart';

/// Teams-style “someone is typing” row: pill bubble + bouncing dots.
class TypingIndicatorBubble extends StatefulWidget {
  const TypingIndicatorBubble({
    super.key,
    this.label,
  });

  /// Optional “Alex is typing…” above the dots (groups).
  final String? label;

  @override
  State<TypingIndicatorBubble> createState() => _TypingIndicatorBubbleState();
}

class _TypingIndicatorBubbleState extends State<TypingIndicatorBubble> {
  /// Same period as the old AnimationController; advanced by a Dart [Timer]
  /// so Windows merged-thread / idle-vsync stalls cannot freeze the dots.
  static const Duration _loop = Duration(milliseconds: 1200);
  static const Duration _tick = Duration(milliseconds: 32);

  Timer? _timer;
  double _t = 0.5;

  @override
  void initState() {
    super.initState();
    privetLowResourceListenable.addListener(_onLowResourceChanged);
    // MediaQuery is not available yet — flag only.
    _applyReduceMotion(privetLowResource);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyReduceMotion(
      privetLowResource || MediaQuery.disableAnimationsOf(context),
    );
  }

  @override
  void dispose() {
    privetLowResourceListenable.removeListener(_onLowResourceChanged);
    _stop();
    super.dispose();
  }

  void _onLowResourceChanged() {
    final osReduce =
        mounted && (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    _applyReduceMotion(privetLowResource || osReduce);
  }

  void _applyReduceMotion(bool reduce) {
    if (!reduce && _timer == null) {
      _timer = Timer.periodic(_tick, (_) {
        if (!mounted) return;
        setState(() {
          _t = (_t + _tick.inMilliseconds / _loop.inMilliseconds) % 1.0;
        });
      });
      if (mounted) setState(() {});
    } else if (reduce && _timer != null) {
      _stop();
      if (mounted) setState(() {});
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _t = 0.5;
  }

  @override
  Widget build(BuildContext context) {
    final animating = _timer != null;
    // Repaint boundary keeps the bouncing dots' per-frame repaint inside this
    // row instead of the whole message list layer.
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.label != null && widget.label!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    widget.label!,
                    style: TextStyle(
                      color: PrivetTheme.mist,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: PrivetTheme.panelElevated,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                    bottomLeft: Radius.circular(4),
                  ),
                  border: Border.all(color: PrivetTheme.line),
                ),
                child: _TypingDots(t: animating ? _t : 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypingDots extends StatelessWidget {
  const _TypingDots({required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final phase = (t + i * 0.2) % 1.0;
        final bounce = phase < 0.5
            ? Curves.easeOut.transform(phase * 2)
            : Curves.easeIn.transform((1 - phase) * 2);
        return Padding(
          padding: EdgeInsets.only(right: i < 2 ? 5 : 0),
          child: Transform.translate(
            offset: Offset(0, -3.5 * bounce),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: PrivetTheme.mist.withValues(alpha: 0.55 + 0.45 * bounce),
              ),
            ),
          ),
        );
      }),
    );
  }
}
