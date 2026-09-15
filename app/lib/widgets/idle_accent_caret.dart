import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Text caret that locks to the live accent while typing, then smoothly cycles
/// through [PrivetTheme.accentOptions] after [idleDelay] of no edits — same
/// feel as Google AI Studio's idle rainbow caret.
class IdleAccentCaret extends StatefulWidget {
  const IdleAccentCaret({
    super.key,
    required this.focusNode,
    required this.controller,
    required this.builder,
    this.idleDelay = const Duration(seconds: 1),
    this.cycleDuration = const Duration(seconds: 5),
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final Widget Function(BuildContext context, Color cursorColor) builder;

  /// How long after the last text edit before the rainbow starts.
  final Duration idleDelay;

  /// Time for one full lap through all accent colors.
  final Duration cycleDuration;

  @override
  State<IdleAccentCaret> createState() => _IdleAccentCaretState();
}

class _IdleAccentCaretState extends State<IdleAccentCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycle;
  Timer? _idleTimer;
  String _lastText = '';
  bool _cycling = false;

  static List<Color> get _palette =>
      PrivetTheme.accentOptions.map((o) => o.seed).toList(growable: false);

  @override
  void initState() {
    super.initState();
    _lastText = widget.controller.text;
    _cycle = AnimationController(vsync: this, duration: widget.cycleDuration)
      ..addListener(_onTick);
    widget.focusNode.addListener(_onFocusChanged);
    widget.controller.addListener(_onControllerChanged);
    // Defer so we don't setState during initState; focus often arrives next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _armIdleOrStop();
    });
  }

  @override
  void didUpdateWidget(covariant IdleAccentCaret oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastText = widget.controller.text;
    }
    if (oldWidget.cycleDuration != widget.cycleDuration) {
      _cycle.duration = widget.cycleDuration;
    }
    _armIdleOrStop();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    widget.focusNode.removeListener(_onFocusChanged);
    widget.controller.removeListener(_onControllerChanged);
    _cycle
      ..removeListener(_onTick)
      ..dispose();
    super.dispose();
  }

  void _onTick() {
    if (mounted && _cycling) setState(() {});
  }

  void _onFocusChanged() => _armIdleOrStop();

  void _onControllerChanged() {
    final text = widget.controller.text;
    if (text == _lastText) return;
    _lastText = text;
    // Typing: snap to the user's accent and restart the idle clock.
    final wasCycling = _cycling;
    _stopCycle();
    _armIdleOrStop();
    if (wasCycling && mounted) setState(() {});
  }

  void _armIdleOrStop() {
    _idleTimer?.cancel();
    if (!widget.focusNode.hasFocus || _animationsDisabled) {
      _stopCycle();
      if (mounted) setState(() {});
      return;
    }
    _idleTimer = Timer(widget.idleDelay, _startCycle);
  }

  bool get _animationsDisabled {
    final mq = MediaQuery.maybeOf(context);
    return mq?.disableAnimations ?? false;
  }

  void _startCycle() {
    if (!mounted || !widget.focusNode.hasFocus || _animationsDisabled) return;
    if (_cycling) return;
    _cycling = true;
    if (!_cycle.isAnimating) {
      _cycle.repeat();
    }
    setState(() {});
  }

  void _stopCycle() {
    _idleTimer?.cancel();
    if (!_cycling && !_cycle.isAnimating) return;
    _cycling = false;
    _cycle.stop();
  }

  Color get _cursorColor {
    if (!_cycling || _animationsDisabled) return PrivetTheme.signal;
    return _colorAt(_cycle.value);
  }

  static Color _colorAt(double t) {
    final colors = _palette;
    final n = colors.length;
    if (n == 0) return PrivetTheme.signal;
    final scaled = (t % 1.0) * n;
    final i = scaled.floor() % n;
    final next = (i + 1) % n;
    return Color.lerp(colors[i], colors[next], scaled - i)!;
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when low-resource / reduce-motion flips.
    final _ = MediaQuery.disableAnimationsOf(context);
    return widget.builder(context, _cursorColor);
  }
}
