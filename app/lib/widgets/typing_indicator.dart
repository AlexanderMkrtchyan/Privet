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

class _TypingIndicatorBubbleState extends State<TypingIndicatorBubble>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

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
    _controller?.dispose();
    super.dispose();
  }

  void _onLowResourceChanged() {
    final osReduce =
        mounted && (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    _applyReduceMotion(privetLowResource || osReduce);
  }

  void _applyReduceMotion(bool reduce) {
    if (!reduce && _controller == null) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      )..repeat();
      if (mounted) setState(() {});
    } else if (reduce && _controller != null) {
      _controller!.dispose();
      _controller = null;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final anim = _controller;
    return Padding(
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
              child: anim == null
                  ? const _TypingDots(t: 0.5)
                  : AnimatedBuilder(
                      animation: anim,
                      builder: (context, _) => _TypingDots(t: anim.value),
                    ),
            ),
          ],
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
