import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state.dart';
import '../theme.dart';
import '../util/english_trainer.dart';

const Color _kFixGreen = Color(0xFF5BD68A);
const Color _kMinorAmber = Color(0xFFFFB547);

Color _issueColor(TrainerIssue i) => i.major ? PrivetTheme.danger : _kMinorAmber;

Future<T?> _showTrainerDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool dismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, _, _) => builder(ctx),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _TrainerFrame extends StatelessWidget {
  const _TrainerFrame({required this.child, this.maxWidth = 560});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: size.width < 520 ? 10 : 24,
          vertical: 24,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: size.height - 48,
          ),
          child: Material(
            color: PrivetTheme.panelElevated,
            elevation: 24,
            shadowColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: PrivetTheme.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Coach avatar — whistle in a glowing ring.
class TrainerCoachAvatar extends StatelessWidget {
  const TrainerCoachAvatar({super.key, this.size = 40, this.mood = 0});

  final double size;

  /// -1 worried, 0 neutral, 1 happy — only tints the ring.
  final int mood;

  @override
  Widget build(BuildContext context) {
    final ring = switch (mood) {
      1 => _kFixGreen,
      -1 => _kMinorAmber,
      _ => PrivetTheme.signal,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ring.withValues(alpha: 0.14),
        border: Border.all(color: ring.withValues(alpha: 0.8), width: 1.5),
        boxShadow: [
          BoxShadow(color: ring.withValues(alpha: 0.25), blurRadius: 14),
        ],
      ),
      child: Icon(
        mood == 1 ? Icons.emoji_events_rounded : Icons.sports_rounded,
        size: size * 0.52,
        color: ring,
      ),
    );
  }
}

class _Kbd extends StatelessWidget {
  const _Kbd(this.label, {this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? PrivetTheme.mist;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: GoogleFonts.ibmPlexMono(fontSize: 10, color: c),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.ibmPlexSans(
          fontSize: 10.5,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
          color: PrivetTheme.mist,
        ),
      ),
    );
  }
}

/// Fade + slide in after [delay] — staggers cards.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 280 + index * 90),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 14),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Review popup (on Enter when the coach found something)
// ---------------------------------------------------------------------------

/// Returns what the user chose; `null` (Esc / tap outside) means edit.
/// [readOnly] shows the lesson for a message that was already sent.
Future<TrainerOutcome?> showTrainerReviewDialog(
  BuildContext context, {
  required TrainerCheck check,
  required TrainerStats stats,
  bool readOnly = false,
}) {
  return _showTrainerDialog<TrainerOutcome>(
    context,
    (_) => _TrainerReviewDialog(check: check, stats: stats, readOnly: readOnly),
  );
}

class _TrainerReviewDialog extends StatefulWidget {
  const _TrainerReviewDialog({
    required this.check,
    required this.stats,
    required this.readOnly,
  });

  final TrainerCheck check;
  final TrainerStats stats;
  final bool readOnly;

  @override
  State<_TrainerReviewDialog> createState() => _TrainerReviewDialogState();
}

class _TrainerReviewDialogState extends State<_TrainerReviewDialog> {
  int? _hover;
  int? _selected;
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final List<GlobalKey> _issueKeys;

  TrainerCheck get _c => widget.check;

  @override
  void initState() {
    super.initState();
    _issueKeys = List.generate(_c.issues.length, (_) => GlobalKey());
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _close(TrainerOutcome? outcome) => Navigator.of(context).pop(outcome);

  void _selectIssue(int i) {
    setState(() {
      _selected = i;
      _hover = i;
    });
    final ctx = _issueKeys[i].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.15,
      );
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (widget.readOnly) {
        _close(null);
      } else if (HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed) {
        _close(TrainerOutcome.sentMine);
      } else {
        _close(TrainerOutcome.sentFixed);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      _close(widget.readOnly ? null : TrainerOutcome.edit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String get _headline {
    final m = _c.majorCount;
    final n = _c.minorCount;
    if (widget.readOnly || m == 0) {
      return n == 1 ? 'One tiny nitpick' : '$n tiny nitpicks';
    }
    return m == 1 ? 'Coach caught a slip' : 'Coach caught $m slips';
  }

  @override
  Widget build(BuildContext context) {
    final quip =
        _c.quip.isNotEmpty ? _c.quip : trainerFallbackQuip(_c.majorCount);
    final fixedIssues = [
      for (final i in _c.issues)
        TrainerIssue(
          wrong: i.right,
          right: i.right,
          type: i.type,
          major: i.major,
          why: '',
          example: '',
        ),
    ];
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: _TrainerFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 10, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TrainerCoachAvatar(mood: _c.hasMajor ? -1 : 0),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _headline,
                          style: GoogleFonts.syne(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: PrivetTheme.paper,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          quip,
                          style: GoogleFonts.ibmPlexSans(
                            fontSize: 13,
                            fontStyle: FontStyle.italic,
                            color: PrivetTheme.mist,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tap a highlighted word for the full explanation',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: PrivetTheme.mist.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_c.cefr != null)
                    Tooltip(
                      message: 'This message reads like ${_c.cefr!.code} '
                          '(${_c.cefr!.title})',
                      child: _LevelPill(level: _c.cefr!, small: true),
                    ),
                  IconButton(
                    tooltip: widget.readOnly ? 'Close' : 'Edit myself (Esc)',
                    onPressed: () =>
                        _close(widget.readOnly ? null : TrainerOutcome.edit),
                    icon: Icon(Icons.close_rounded, color: PrivetTheme.mist),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SectionLabel('You wrote'),
                    _HighlightedText(
                      text: _c.original,
                      issues: _c.issues,
                      hover: _hover,
                      selected: _selected,
                      onHover: (i) => setState(() => _hover = i),
                      onSelect: _selectIssue,
                      mode: _HighlightMode.wrong,
                    ),
                    const SizedBox(height: 12),
                    const _SectionLabel('Coach’s version'),
                    _HighlightedText(
                      text: _c.corrected,
                      issues: fixedIssues,
                      hover: _hover,
                      selected: _selected,
                      onHover: (i) => setState(() => _hover = i),
                      onSelect: _selectIssue,
                      mode: _HighlightMode.fixed,
                    ),
                    const SizedBox(height: 14),
                    for (var i = 0; i < _c.issues.length; i++)
                      KeyedSubtree(
                        key: _issueKeys[i],
                        child: _Entrance(
                          index: i,
                          child: MouseRegion(
                            onEnter: (_) => setState(() => _hover = i),
                            onExit: (_) => setState(() => _hover = null),
                            child: GestureDetector(
                              onTap: () => _selectIssue(i),
                              child: _IssueCard(
                                n: i + 1,
                                issue: _c.issues[i],
                                active: _hover == i || _selected == i,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_c.natural.isNotEmpty)
                      _Entrance(
                        index: _c.issues.length,
                        child: _NativeTip(
                          text: _c.natural,
                          onSend: widget.readOnly
                              ? null
                              : () => _close(TrainerOutcome.sentNatural),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: PrivetTheme.line),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: widget.readOnly
                  ? Row(
                      children: [
                        Expanded(child: _StreakNote(stats: widget.stats)),
                        FilledButton(
                          onPressed: () => _close(null),
                          child: const Text('Got it'),
                        ),
                      ],
                    )
                  : Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_c.hasMajor && widget.stats.streak > 0)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.local_fire_department_rounded,
                                  size: 15,
                                  color: _kMinorAmber,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Fix it yourself to earn a bonus',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: PrivetTheme.mist,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        TextButton(
                          onPressed: () => _close(TrainerOutcome.edit),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [Text('Edit myself'), _Kbd('Esc')],
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () => _close(TrainerOutcome.sentMine),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [Text('Send mine'), _Kbd('Ctrl ⏎')],
                          ),
                        ),
                        if (_c.natural.trim().isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () =>
                                _close(TrainerOutcome.sentNatural),
                            icon: const Icon(
                              Icons.record_voice_over_rounded,
                              size: 18,
                            ),
                            label: const Text('Send native'),
                          ),
                        FilledButton.icon(
                          onPressed: () => _close(TrainerOutcome.sentFixed),
                          icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Send fixed'),
                              _Kbd('⏎', color: PrivetTheme.onAccent),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _HighlightMode { wrong, fixed }

class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.issues,
    required this.hover,
    required this.onHover,
    required this.mode,
    this.selected,
    this.onSelect,
  });

  final String text;
  final List<TrainerIssue> issues;
  final int? hover;
  final int? selected;
  final ValueChanged<int?> onHover;
  final ValueChanged<int>? onSelect;
  final _HighlightMode mode;

  @override
  Widget build(BuildContext context) {
    final spans = trainerIssueSpans(text, issues);
    final base = GoogleFonts.ibmPlexSans(
      fontSize: 15,
      height: 1.5,
      color: PrivetTheme.paper,
    );
    final children = <InlineSpan>[];
    var at = 0;
    for (final s in spans) {
      if (s.start > at) {
        children.add(TextSpan(text: text.substring(at, s.start)));
      }
      final issue = issues[s.issue];
      final color =
          mode == _HighlightMode.fixed ? _kFixGreen : _issueColor(issue);
      final active = hover == s.issue || selected == s.issue;
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: GestureDetector(
            onTap: onSelect == null ? null : () => onSelect!(s.issue),
            onTapDown: (_) => onHover(s.issue),
            child: MouseRegion(
              cursor: onSelect == null
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              onEnter: (_) => onHover(s.issue),
              onExit: (_) => onHover(null),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: active ? 0.34 : 0.14),
                  borderRadius: BorderRadius.circular(4),
                  border: selected == s.issue
                      ? Border.all(color: color.withValues(alpha: 0.7))
                      : null,
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: text.substring(s.start, s.end),
                        style: TextStyle(
                          color: mode == _HighlightMode.fixed
                              ? _kFixGreen
                              : PrivetTheme.paper,
                          fontWeight: FontWeight.w600,
                          decoration: mode == _HighlightMode.wrong
                              ? TextDecoration.underline
                              : null,
                          decorationStyle: TextDecorationStyle.wavy,
                          decorationColor: color,
                        ),
                      ),
                      TextSpan(
                        text: ' ${s.issue + 1}',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                  style: base,
                ),
              ),
            ),
          ),
        ),
      );
      at = s.end;
    }
    if (at < text.length) children.add(TextSpan(text: text.substring(at)));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PrivetTheme.ink.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (mode == _HighlightMode.fixed
                  ? _kFixGreen
                  : PrivetTheme.line)
              .withValues(alpha: mode == _HighlightMode.fixed ? 0.35 : 1),
        ),
      ),
      child: Text.rich(TextSpan(style: base, children: children)),
    );
  }
}

class _IssueCard extends StatelessWidget {
  const _IssueCard({
    required this.n,
    required this.issue,
    required this.active,
  });

  final int n;
  final TrainerIssue issue;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = _issueColor(issue);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: active ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: color, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 9,
                backgroundColor: color,
                child: Text(
                  '$n',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                trainerIssueTypeLabel(issue.type).toUpperCase(),
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 10.5,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                issue.major ? '· mistake' : '· nitpick',
                style: TextStyle(fontSize: 11, color: PrivetTheme.mist),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                issue.wrong.isEmpty ? '∅' : issue.wrong,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 15,
                  color: color,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: color,
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: PrivetTheme.mist,
              ),
              Text(
                issue.right.isEmpty ? '(remove)' : issue.right,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _kFixGreen,
                ),
              ),
            ],
          ),
          if (issue.why.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              issue.why,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 13,
                color: PrivetTheme.paper.withValues(alpha: 0.9),
              ),
            ),
          ],
          if (issue.example.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.format_quote_rounded,
                  size: 15,
                  color: PrivetTheme.mist,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    issue.example,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                      color: PrivetTheme.mist,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _NativeTip extends StatelessWidget {
  const _NativeTip({required this.text, this.onSend});

  final String text;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PrivetTheme.signal.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PrivetTheme.signal.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.record_voice_over_rounded,
                  size: 18, color: PrivetTheme.signal),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'How a native might say it',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: PrivetTheme.signal,
                      ),
                    ),
                    const SizedBox(height: 3),
                    SelectableText(
                      text,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 14,
                        color: PrivetTheme.paper,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (onSend != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onSend,
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('Send this instead'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StreakNote extends StatelessWidget {
  const _StreakNote({required this.stats});

  final TrainerStats stats;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.local_fire_department_rounded,
          size: 16,
          color: stats.streak > 0 ? _kMinorAmber : PrivetTheme.mist,
        ),
        const SizedBox(width: 4),
        Text(
          stats.streak > 0
              ? 'Streak ${stats.streak} — nitpicks don’t break it'
              : 'Nitpicks don’t break your streak',
          style: TextStyle(fontSize: 12, color: PrivetTheme.mist),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Toast after a send
// ---------------------------------------------------------------------------

/// SnackBar body for trainer feedback.
class TrainerToast extends StatelessWidget {
  const TrainerToast({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.xp = 0,
    this.streak,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final int xp;
  final int? streak;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.4, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.elasticOut,
          builder: (context, s, child) =>
              Transform.scale(scale: s, child: child),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.ibmPlexSans(
                  fontWeight: FontWeight.w600,
                  color: PrivetTheme.paper,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: PrivetTheme.mist),
                ),
            ],
          ),
        ),
        if (streak != null && streak! > 0) ...[
          const SizedBox(width: 8),
          const Icon(
            Icons.local_fire_department_rounded,
            size: 16,
            color: _kMinorAmber,
          ),
          Text(
            '$streak',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: _kMinorAmber,
            ),
          ),
        ],
        if (xp > 0) ...[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: PrivetTheme.signal.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '+$xp XP',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: PrivetTheme.signal,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard popup
// ---------------------------------------------------------------------------

Future<void> showTrainerDashboard(BuildContext context, PrivetState state) {
  return _showTrainerDialog<void>(
    context,
    (_) => _TrainerDashboard(state: state),
  );
}

class _TrainerDashboard extends StatefulWidget {
  const _TrainerDashboard({required this.state});

  final PrivetState state;

  @override
  State<_TrainerDashboard> createState() => _TrainerDashboardState();
}

class _TrainerDashboardState extends State<_TrainerDashboard> {
  bool _reviewing = false;
  String? _reviewError;

  /// Bumped after a fresh review so the reveal animation replays.
  int _revealGen = 0;

  PrivetState get _state => widget.state;
  TrainerStats get _stats => _state.trainerStats;

  Future<void> _review() async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _reviewError = null;
    });
    try {
      await _state.reviewEnglishLevel();
      if (!mounted) return;
      setState(() => _revealGen++);
    } catch (e) {
      if (!mounted) return;
      setState(() => _reviewError = _errText(e));
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PrivetTheme.panelElevated,
        title: const Text('Reset trainer progress?'),
        content: const Text(
          'Streaks, XP, mistakes and your grade on this device will be wiped. '
          'The coach will pretend it never met you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: PrivetTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _state.resetTrainerStats();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final report = stats.lastReport;
    final canReview =
        stats.samples.length >= TrainerStats.minSamplesForReview &&
            _state.trainerAiAvailable;
    return _TrainerFrame(
      maxWidth: 620,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
            child: Row(
              children: [
                TrainerCoachAvatar(mood: report == null ? 0 : 1, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'English Coach',
                        style: GoogleFonts.syne(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: PrivetTheme.paper,
                        ),
                      ),
                      Text(
                        _state.englishTrainerEnabled
                            ? 'Checking every English message before it goes out'
                            : 'Off — turn on to get checked before sending',
                        style: TextStyle(fontSize: 12, color: PrivetTheme.mist),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: 'Personal trainer',
                  child: Switch(
                    value: _state.englishTrainerEnabled,
                    activeThumbColor: PrivetTheme.onAccent,
                    activeTrackColor: PrivetTheme.signal,
                    onChanged: (v) async {
                      await _state.setEnglishTrainerEnabled(v);
                      if (mounted) setState(() {});
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close_rounded, color: PrivetTheme.mist),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LevelHero(
                    key: ValueKey(_revealGen),
                    stats: stats,
                    report: report,
                    animate: _revealGen > 0,
                  ),
                  const SizedBox(height: 12),
                  _ReviewButton(
                    busy: _reviewing,
                    enabled: canReview,
                    hasReport: report != null,
                    samples: stats.samples.length,
                    aiAvailable: _state.trainerAiAvailable,
                    onTap: _review,
                  ),
                  if (_reviewError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _reviewError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, color: PrivetTheme.danger),
                    ),
                  ],
                  if (report != null) ...[
                    const SizedBox(height: 16),
                    _ReportDetails(key: ValueKey('r$_revealGen'), report: report),
                  ],
                  const SizedBox(height: 18),
                  const _SectionLabel('Your numbers'),
                  _StatsGrid(stats: stats),
                  const SizedBox(height: 14),
                  _RankBar(stats: stats),
                  if (stats.topTypes.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const _SectionLabel('Weak spots'),
                    _WeakSpots(stats: stats),
                  ],
                  if (stats.mistakes.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const _SectionLabel('Recent slips'),
                    Text(
                      'Tap a slip to revise the full lesson',
                      style: TextStyle(fontSize: 12, color: PrivetTheme.mist),
                    ),
                    const SizedBox(height: 8),
                    for (final m in stats.mistakes.reversed.take(10))
                      _MistakeLessonTile(
                        mistake: m,
                        onOpen: () {
                          final siblings = stats.siblingsOf(m);
                          final check = m.toCheck(
                            allIssues: [
                              for (final s in siblings) s.asIssue,
                            ],
                          );
                          showTrainerReviewDialog(
                            context,
                            check: check,
                            stats: stats,
                            readOnly: true,
                          );
                        },
                      ),
                  ],
                  if (stats.checked == 0) ...[
                    const SizedBox(height: 18),
                    _EmptyHint(enabled: _state.englishTrainerEnabled),
                  ],
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: stats.checked == 0 && stats.xp == 0
                          ? null
                          : _reset,
                      icon: Icon(
                        Icons.restart_alt_rounded,
                        size: 16,
                        color: PrivetTheme.mist,
                      ),
                      label: Text(
                        'Reset progress',
                        style: TextStyle(color: PrivetTheme.mist, fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _errText(Object e) =>
    e is StateError ? e.message : e.toString().replaceFirst('Exception: ', '');

class _LevelPill extends StatelessWidget {
  const _LevelPill({required this.level, this.small = false});

  final CefrLevel level;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: small ? 8 : 12,
        vertical: small ? 3 : 6,
      ),
      decoration: BoxDecoration(
        color: PrivetTheme.signal.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: PrivetTheme.signal.withValues(alpha: 0.6)),
      ),
      child: Text(
        level.code,
        style: GoogleFonts.syne(
          fontSize: small ? 12 : 16,
          fontWeight: FontWeight.w800,
          color: PrivetTheme.signal,
        ),
      ),
    );
  }
}

class _LevelHero extends StatelessWidget {
  const _LevelHero({
    super.key,
    required this.stats,
    required this.report,
    required this.animate,
  });

  final TrainerStats stats;
  final TrainerLevelReport? report;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final prev = stats.previousReport;
    String? delta;
    if (r != null && prev != null) {
      final now = r.level.index * 100 + r.progress;
      final before = prev.level.index * 100 + prev.progress;
      if (r.level != prev.level) {
        delta = r.level.index > prev.level.index
            ? 'Level up from ${prev.level.code}!'
            : 'Down from ${prev.level.code} — bad day?';
      } else if (now != before) {
        delta = now > before
            ? '+${now - before}% since last review'
            : '${now - before}% since last review';
      }
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            PrivetTheme.signal.withValues(alpha: 0.16),
            PrivetTheme.ink.withValues(alpha: 0.3),
          ],
        ),
        border: Border.all(color: PrivetTheme.signal.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: animate ? 0.3 : 1, end: 1),
                duration: const Duration(milliseconds: 700),
                curve: Curves.elasticOut,
                builder: (context, s, child) =>
                    Transform.scale(scale: s, child: child),
                child: Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: r == null
                        ? PrivetTheme.paper.withValues(alpha: 0.06)
                        : PrivetTheme.signal,
                    boxShadow: r == null
                        ? null
                        : [
                            BoxShadow(
                              color: PrivetTheme.signal.withValues(alpha: 0.45),
                              blurRadius: 22,
                            ),
                          ],
                  ),
                  child: Text(
                    r?.level.code ?? '?',
                    style: GoogleFonts.syne(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: r == null ? PrivetTheme.mist : PrivetTheme.onAccent,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r == null ? 'Not graded yet' : r.level.title,
                      style: GoogleFonts.syne(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: PrivetTheme.paper,
                      ),
                    ),
                    if (r != null && r.title.isNotEmpty)
                      Text(
                        '“${r.title}”',
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                          color: PrivetTheme.signal,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      r == null
                          ? 'Chat in English with the trainer on, then ask the '
                              'coach for a grade.'
                          : r.level.blurb,
                      style: TextStyle(fontSize: 12.5, color: PrivetTheme.mist),
                    ),
                    if (delta != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        delta,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _kFixGreen,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _CefrLadder(report: r, animate: animate),
          if (r != null) ...[
            const SizedBox(height: 6),
            Text(
              r.level.next == null
                  ? 'Top of the ladder — ${r.progress}% of C2 mastered'
                  : '${r.progress}% through ${r.level.code} · '
                      '${100 - r.progress}% to ${r.level.next!.code}',
              style: TextStyle(fontSize: 11.5, color: PrivetTheme.mist),
            ),
          ],
        ],
      ),
    );
  }
}

class _CefrLadder extends StatelessWidget {
  const _CefrLadder({required this.report, required this.animate});

  final TrainerLevelReport? report;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final r = report;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: animate ? 0 : 1, end: 1),
      duration: const Duration(milliseconds: 1100),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) {
        return Row(
          children: [
            for (final level in CefrLevel.values) ...[
              Expanded(
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        height: 8,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(
                              color: PrivetTheme.paper.withValues(alpha: 0.08),
                            ),
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: _fill(level, r, t),
                              child: ColoredBox(color: PrivetTheme.signal),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      level.code,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: r?.level == level
                            ? FontWeight.w800
                            : FontWeight.w500,
                        color: r?.level == level
                            ? PrivetTheme.signal
                            : PrivetTheme.mist,
                      ),
                    ),
                  ],
                ),
              ),
              if (level != CefrLevel.c2) const SizedBox(width: 4),
            ],
          ],
        );
      },
    );
  }

  /// Each segment fills in order as [t] sweeps 0 → [TrainerLevelReport.ladderPosition].
  static double _fill(CefrLevel level, TrainerLevelReport? r, double t) {
    if (r == null) return 0;
    final n = CefrLevel.values.length;
    final pos = r.ladderPosition * t * n;
    return (pos - level.index).clamp(0.0, 1.0);
  }
}

class _ReviewButton extends StatelessWidget {
  const _ReviewButton({
    required this.busy,
    required this.enabled,
    required this.hasReport,
    required this.samples,
    required this.aiAvailable,
    required this.onTap,
  });

  final bool busy;
  final bool enabled;
  final bool hasReport;
  final int samples;
  final bool aiAvailable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final need = TrainerStats.minSamplesForReview - samples;
    final label = busy
        ? 'Coach is grading your homework…'
        : hasReport
            ? 'Review my English level again'
            : 'Review my English level';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: enabled && !busy ? onTap : null,
          icon: busy
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: PrivetTheme.onAccent,
                  ),
                )
              : const Icon(Icons.school_rounded),
          label: Text(
            label,
            style: GoogleFonts.ibmPlexSans(
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
        if (!enabled && !busy) ...[
          const SizedBox(height: 6),
          Text(
            !aiAvailable
                ? 'Needs AI — add a DeepSeek key in Profile & settings'
                : 'Send $need more English message${need == 1 ? '' : 's'} '
                    'with the trainer on to unlock grading',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: PrivetTheme.mist),
          ),
          if (aiAvailable) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: samples / TrainerStats.minSamplesForReview,
                color: PrivetTheme.signal,
                backgroundColor: PrivetTheme.paper.withValues(alpha: 0.08),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _ReportDetails extends StatelessWidget {
  const _ReportDetails({super.key, required this.report});

  final TrainerLevelReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (r.verdict.isNotEmpty)
          _Entrance(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: PrivetTheme.ink.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.sports_rounded, size: 18, color: PrivetTheme.signal),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      r.verdict,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13.5,
                        height: 1.4,
                        color: PrivetTheme.paper,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        _Entrance(
          index: 1,
          child: LayoutBuilder(
            builder: (context, c) {
              final strengths = _BulletList(
                title: 'Nailing it',
                icon: Icons.check_circle_rounded,
                color: _kFixGreen,
                items: r.strengths,
              );
              final weak = _BulletList(
                title: 'Work on',
                icon: Icons.construction_rounded,
                color: _kMinorAmber,
                items: r.weaknesses,
              );
              if (c.maxWidth < 440) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [strengths, const SizedBox(height: 10), weak],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: strengths),
                  const SizedBox(width: 12),
                  Expanded(child: weak),
                ],
              );
            },
          ),
        ),
        if (r.nextGoal.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Entrance(
            index: 2,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: PrivetTheme.signal.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.flag_rounded, size: 18, color: PrivetTheme.signal),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: r.level.next == null
                                ? 'Stay sharp: '
                                : 'Road to ${r.level.next!.code}: ',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: r.nextGoal),
                        ],
                      ),
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13,
                        color: PrivetTheme.paper,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (r.drills.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SectionLabel('Quick drills — tap to reveal'),
          for (var i = 0; i < r.drills.length; i++)
            _Entrance(
              index: 3 + i,
              child: _DrillCard(n: i + 1, drill: r.drills[i]),
            ),
        ],
      ],
    );
  }
}

class _BulletList extends StatelessWidget {
  const _BulletList({
    required this.title,
    required this.icon,
    required this.color,
    required this.items,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 13, color: color),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 12.5,
                        color: PrivetTheme.paper,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DrillCard extends StatefulWidget {
  const _DrillCard({required this.n, required this.drill});

  final int n;
  final TrainerDrill drill;

  @override
  State<_DrillCard> createState() => _DrillCardState();
}

class _DrillCardState extends State<_DrillCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.drill;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: PrivetTheme.paper.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.n}.',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: PrivetTheme.signal,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        d.prompt,
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: 14,
                          color: PrivetTheme.paper,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: PrivetTheme.mist,
                      ),
                    ),
                  ],
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topLeft,
                  child: !_open
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 8, left: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                d.answer,
                                style: GoogleFonts.ibmPlexSans(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: _kFixGreen,
                                ),
                              ),
                              if (d.tip.isNotEmpty)
                                Text(
                                  d.tip,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: PrivetTheme.mist,
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});

  final TrainerStats stats;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _StatTile(
        icon: Icons.chat_bubble_outline_rounded,
        value: '${stats.checked}',
        label: 'checked',
      ),
      _StatTile(
        icon: Icons.verified_rounded,
        value: stats.checked == 0
            ? '—'
            : '${(stats.cleanRate * 100).round()}%',
        label: 'clean',
        color: _kFixGreen,
      ),
      _StatTile(
        icon: Icons.local_fire_department_rounded,
        value: '${stats.streak}',
        label: 'streak · best ${stats.bestStreak}',
        color: _kMinorAmber,
      ),
      _StatTile(
        icon: Icons.bug_report_outlined,
        value: '${stats.majorErrors}',
        label: 'mistakes · ${stats.minorErrors} nitpicks',
        color: PrivetTheme.danger,
      ),
      _StatTile(
        icon: Icons.handyman_rounded,
        value: '${stats.selfFixes}',
        label: 'fixed myself',
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth < 420 ? 2 : 3;
        final w = (c.maxWidth - (cols - 1) * 8) / cols;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final t in tiles) SizedBox(width: w, child: t)],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? PrivetTheme.signal;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: PrivetTheme.paper.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: GoogleFonts.syne(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: PrivetTheme.paper,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: PrivetTheme.mist),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RankBar extends StatelessWidget {
  const _RankBar({required this.stats});

  final TrainerStats stats;

  @override
  Widget build(BuildContext context) {
    final next = stats.nextRank;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PrivetTheme.paper.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.military_tech_rounded,
                  size: 18, color: PrivetTheme.signal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stats.rank.title,
                  style: GoogleFonts.syne(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: PrivetTheme.paper,
                  ),
                ),
              ),
              Text(
                '${stats.xp} XP',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: PrivetTheme.signal,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: stats.rankProgress,
              color: PrivetTheme.signal,
              backgroundColor: PrivetTheme.paper.withValues(alpha: 0.08),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            next == null
                ? 'Max rank. The coach bows to you.'
                : '${next.xp - stats.xp} XP to ${next.title} · '
                    'clean messages +10, streak bonus, self-fixes +8',
            style: TextStyle(fontSize: 11, color: PrivetTheme.mist),
          ),
        ],
      ),
    );
  }
}

class _WeakSpots extends StatelessWidget {
  const _WeakSpots({required this.stats});

  final TrainerStats stats;

  @override
  Widget build(BuildContext context) {
    final top = stats.topTypes.take(5).toList();
    final max = top.first.value;
    return Column(
      children: [
        for (var i = 0; i < top.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 104,
                  child: Text(
                    trainerIssueTypeLabel(top[i].key),
                    style: TextStyle(fontSize: 12.5, color: PrivetTheme.paper),
                  ),
                ),
                Expanded(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: top[i].value / max),
                    duration: Duration(milliseconds: 500 + i * 120),
                    curve: Curves.easeOutCubic,
                    builder: (context, v, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: v,
                        color: i == 0 ? PrivetTheme.danger : _kMinorAmber,
                        backgroundColor:
                            PrivetTheme.paper.withValues(alpha: 0.06),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 34,
                  child: Text(
                    '${top[i].value}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: PrivetTheme.mist,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MistakeLessonTile extends StatefulWidget {
  const _MistakeLessonTile({
    required this.mistake,
    required this.onOpen,
  });

  final TrainerMistake mistake;
  final VoidCallback onOpen;

  @override
  State<_MistakeLessonTile> createState() => _MistakeLessonTileState();
}

class _MistakeLessonTileState extends State<_MistakeLessonTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.mistake;
    final color = m.major ? PrivetTheme.danger : _kMinorAmber;
    final hasContext = m.original.trim().isNotEmpty;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: _open ? 0.10 : 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: _open ? 0.45 : 0.22),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _open = !_open),
          onLongPress: widget.onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      _open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: PrivetTheme.mist,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        m.wrong.isEmpty ? '∅' : m.wrong,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: color,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: color,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(
                        Icons.arrow_forward_rounded,
                        size: 14,
                        color: PrivetTheme.mist,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        m.right.isEmpty ? '(remove)' : m.right,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _kFixGreen,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      trainerIssueTypeLabel(m.type),
                      style: TextStyle(fontSize: 11, color: PrivetTheme.mist),
                    ),
                  ],
                ),
                if (_open) ...[
                  const SizedBox(height: 10),
                  if (hasContext) ...[
                    Text(
                      'YOUR MESSAGE',
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 10,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: PrivetTheme.mist,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      m.original,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13.5,
                        height: 1.45,
                        color: PrivetTheme.paper,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (m.why.isNotEmpty)
                    Text(
                      m.why,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13.5,
                        height: 1.4,
                        color: PrivetTheme.paper.withValues(alpha: 0.92),
                      ),
                    )
                  else
                    Text(
                      'No explanation was saved for this older slip.',
                      style: TextStyle(fontSize: 12.5, color: PrivetTheme.mist),
                    ),
                  if (m.example.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.format_quote_rounded,
                          size: 15,
                          color: PrivetTheme.mist,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            m.example,
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 13,
                              fontStyle: FontStyle.italic,
                              color: PrivetTheme.mist,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (m.corrected.trim().isNotEmpty &&
                      m.corrected.trim() != m.original.trim()) ...[
                    const SizedBox(height: 10),
                    Text(
                      'COACH’S VERSION',
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 10,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: PrivetTheme.mist,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      m.corrected,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13.5,
                        height: 1.45,
                        color: _kFixGreen,
                      ),
                    ),
                  ],
                  if (m.natural.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      'NATIVE VIBE',
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 10,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: PrivetTheme.mist,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      m.natural,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        height: 1.4,
                        color: PrivetTheme.mist,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: widget.onOpen,
                      icon: const Icon(Icons.menu_book_rounded, size: 16),
                      label: const Text('Open full lesson'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PrivetTheme.line),
      ),
      child: Text(
        enabled
            ? 'Warm-up time. Write any English message and hit Enter — the '
                'coach reads it first. Clean ones fly straight out and earn XP; '
                'slips open a quick lesson.'
            : 'Flip the switch above, then just chat. The coach checks English '
                'messages before they send. Nitpicks never block you; real '
                'mistakes get a quick lesson.',
        style: GoogleFonts.ibmPlexSans(
          fontSize: 13,
          height: 1.45,
          color: PrivetTheme.mist,
        ),
      ),
    );
  }
}
