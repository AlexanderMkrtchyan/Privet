import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/composer_autocorrect.dart';
import '../util/low_resource.dart';
import '../util/rich_text_markup.dart';

/// Active Teams-style autocorrect highlight in the composer.
class AutocorrectMark {
  AutocorrectMark({
    required this.start,
    required this.end,
    required this.original,
    required this.corrected,
    required this.createdAt,
  });

  int start;
  int end;
  final String original;
  final String corrected;
  final DateTime createdAt;
}

/// Composer [TextEditingController] with autocorrect flash + red spell underlines.
///
/// Undo: one Backspace immediately after a correction (caret still at the
/// post-correct position) restores the typo. Hover + left-click a red
/// underline for up to 3 spelling suggestions (Teams-style).
class ComposerAutocorrectController extends TextEditingController {
  ComposerAutocorrectController({super.text});

  AutocorrectMark? _mark;
  List<SpellIssue> _issues = const [];
  SpellIssue? _hoveredIssue;
  double _fade = 0;
  AnimationController? _fadeCtrl;
  Timer? _ttl;
  Timer? _undoArmTtl;
  bool _applying = false;

  /// Rich-text format runs over the plain composer text (see
  /// `rich_text_markup.dart`). Kept in sync as the text is edited.
  List<FormatRun> _formatRuns = [];
  bool _loadingMarkup = false;

  List<FormatRun> get formatRuns => _formatRuns;

  /// The message body to send: plain text with formatting tags embedded.
  String get markupText => serializeMarkup(text, _formatRuns);

  /// Replaces the runs (e.g. from a toolbar action). The selection is kept.
  void setFormatRuns(List<FormatRun> runs) {
    _formatRuns = runs;
    notifyListeners();
    refreshSpelling();
  }

  void clearFormatRuns() {
    if (_formatRuns.isEmpty) return;
    _formatRuns = [];
    notifyListeners();
  }

  /// Loads a stored message body (may contain markup) into the composer as
  /// plain text + format runs.
  void loadMarkup(String markup) {
    final parsed = parseMarkup(markup);
    _loadingMarkup = true;
    try {
      _formatRuns = parsed.runs;
      _mark = null;
      _issues = const [];
      _hoveredIssue = null;
      value = TextEditingValue(
        text: parsed.plainText,
        selection: TextSelection.collapsed(offset: parsed.plainText.length),
      );
    } finally {
      _loadingMarkup = false;
    }
    refreshSpelling();
  }

  @override
  set value(TextEditingValue newValue) {
    if (!_loadingMarkup) {
      _shiftRunsForEdit(oldText: text, newText: newValue.text);
    }
    super.value = newValue;
  }

  /// Adjusts format runs when the text changes (insertions / deletions /
  /// replacements). Deleted text loses its formatting; text inserted inside an
  /// existing run inherits that run's format.
  void _shiftRunsForEdit({required String oldText, required String newText}) {
    if (_formatRuns.isEmpty || oldText == newText) return;

    var prefix = 0;
    final maxPrefix = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    while (prefix < maxPrefix && oldText[prefix] == newText[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < oldText.length - prefix &&
        suffix < newText.length - prefix &&
        oldText[oldText.length - 1 - suffix] ==
            newText[newText.length - 1 - suffix]) {
      suffix++;
    }

    final editStart = prefix;
    final editOldEnd = oldText.length - suffix;
    final editNewEnd = newText.length - suffix;
    final delta = newText.length - oldText.length;
    final pureInsert = editOldEnd == editStart && delta != 0;

    final shifted = <FormatRun>[];
    for (final r in _formatRuns) {
      if (pureInsert && r.start < editStart && r.end >= editStart) {
        shifted.add(
          FormatRun(
            r.start,
            (r.end + delta).clamp(r.start, newText.length),
            r.format,
          ),
        );
        continue;
      }
      if (r.end <= editStart) {
        shifted.add(r);
      } else if (r.start >= editOldEnd) {
        shifted.add(
          FormatRun(r.start + delta, r.end + delta, r.format),
        );
      } else {
        final keepBefore = r.start < editStart;
        final keepAfter = r.end > editOldEnd;
        if (keepBefore && keepAfter) {
          shifted.add(FormatRun(r.start, editStart, r.format));
          shifted.add(FormatRun(editNewEnd, r.end + delta, r.format));
        } else if (keepBefore) {
          shifted.add(FormatRun(r.start, editStart, r.format));
        } else if (keepAfter) {
          shifted.add(
            FormatRun(editNewEnd.clamp(0, newText.length), r.end + delta, r.format),
          );
        }
      }
    }

    final next = <FormatRun>[];
    for (final r in shifted) {
      final s = r.start.clamp(0, newText.length);
      final e = r.end.clamp(0, newText.length);
      if (e > s) next.add(FormatRun(s, e, r.format));
    }
    _formatRuns = next;
  }

  bool _backspaceUndoArmed = false;
  int _undoCaret = -1;

  /// In-app red-underline spelling + autocorrect flash, synced from settings.
  /// When false, existing marks/underlines are dropped and new ones suppressed.
  bool spellCheckEnabled = true;

  final Set<String> _suppressed = {};

  AutocorrectMark? get mark => _mark;
  List<SpellIssue> get spellIssues => _issues;
  SpellIssue? get hoveredSpellIssue => _hoveredIssue;
  bool get isApplying => _applying;
  bool get backspaceUndoArmed => _backspaceUndoArmed;

  void attachTicker(TickerProvider vsync) {
    _fadeCtrl?.dispose();
    _fadeCtrl = AnimationController(
      vsync: vsync,
      duration: privetAnim(const Duration(milliseconds: 2000)),
    )..addListener(() {
        _fade = 1.0 - _fadeCtrl!.value;
        notifyListeners();
      });
  }

  void clearMarks() {
    _ttl?.cancel();
    _ttl = null;
    _disarmBackspaceUndo();
    _fadeCtrl?.stop();
    _mark = null;
    _fade = 0;
    _hoveredIssue = null;
    notifyListeners();
  }

  void _disarmBackspaceUndo() {
    _undoArmTtl?.cancel();
    _undoArmTtl = null;
    _backspaceUndoArmed = false;
    _undoCaret = -1;
  }

  @override
  void clear() {
    clearMarks();
    _issues = const [];
    _suppressed.clear();
    _formatRuns = [];
    super.clear();
  }

  /// Refresh red-underline misspellings for the current text.
  void refreshSpelling() {
    if (_applying) return;
    if (!spellCheckEnabled) {
      if (_issues.isNotEmpty || _hoveredIssue != null) {
        _issues = const [];
        _hoveredIssue = null;
        notifyListeners();
      }
      return;
    }
    if (!ComposerAutocorrectDictionary.instance.isReady) {
      if (_issues.isNotEmpty) {
        _issues = const [];
        notifyListeners();
      }
      return;
    }
    final next = ComposerAutocorrectDictionary.instance.findSpellIssues(text);
    // Drop issues that overlap the live autocorrect flash.
    final m = _mark;
    final filtered = (m == null)
        ? next
        : next
            .where((i) => i.end <= m.start || i.start >= m.end)
            .toList(growable: false);
    if (_sameIssues(_issues, filtered)) return;
    _issues = filtered;
    // Drop hover if that span disappeared.
    if (_hoveredIssue != null &&
        !_issues.any(
          (e) =>
              e.start == _hoveredIssue!.start &&
              e.end == _hoveredIssue!.end &&
              e.word == _hoveredIssue!.word,
        )) {
      _hoveredIssue = null;
    }
    notifyListeners();
  }

  static bool _sameIssues(List<SpellIssue> a, List<SpellIssue> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].start != b[i].start ||
          a[i].end != b[i].end ||
          a[i].word != b[i].word) {
        return false;
      }
      if (a[i].suggestions.length != b[i].suggestions.length) return false;
      for (var j = 0; j < a[i].suggestions.length; j++) {
        if (a[i].suggestions[j] != b[i].suggestions[j]) return false;
      }
    }
    return true;
  }

  SpellIssue? spellIssueAt(int offset) {
    for (final issue in _issues) {
      if (issue.containsOffset(offset)) return issue;
    }
    return null;
  }

  /// Teams-style hover: paint the underlined word like a soft selection.
  void setHoveredSpellIssue(SpellIssue? issue) {
    if (_hoveredIssue?.start == issue?.start &&
        _hoveredIssue?.end == issue?.end &&
        _hoveredIssue?.word == issue?.word) {
      return;
    }
    _hoveredIssue = issue;
    notifyListeners();
  }

  /// Replace a misspelled span with a suggestion from the Spelling menu.
  ///
  /// Pass [editable] on web so the browser text input stays in sync — setting
  /// [value] alone can race with a click-through and wipe the field.
  void applySpellSuggestion(
    SpellIssue issue,
    String suggestion, {
    EditableTextState? editable,
  }) {
    if (_applying) return;
    final t = text;
    if (issue.start < 0 ||
        issue.end > t.length ||
        t.substring(issue.start, issue.end) != issue.word) {
      refreshSpelling();
      return;
    }
    _applying = true;
    try {
      final nextText = t.replaceRange(issue.start, issue.end, suggestion);
      final caret = (issue.start + suggestion.length).clamp(0, nextText.length);
      _suppressed.add(issue.word.toLowerCase());
      final next = TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: caret),
      );
      if (editable != null) {
        editable.userUpdateTextEditingValue(
          next,
          SelectionChangedCause.toolbar,
        );
      } else {
        value = next;
      }
    } finally {
      _applying = false;
    }
    refreshSpelling();
  }

  /// Replace a span without autocorrect flash (e.g. live emoticon expansion).
  void applySilentReplacement({
    required int start,
    required int end,
    required String replacement,
    required int caretAfter,
  }) {
    if (_applying) return;
    _applying = true;
    try {
      final text = this.text;
      final s = start.clamp(0, text.length);
      final e = end.clamp(s, text.length);
      if (text.substring(s, e) == replacement) return;
      final next = text.replaceRange(s, e, replacement);
      final delta = replacement.length - (e - s);
      final caret = (caretAfter + delta).clamp(0, next.length);
      value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: caret),
      );
    } finally {
      _applying = false;
    }
  }

  void applyCorrection(AutocorrectAttempt attempt, {required int caretAfter}) {
    if (_applying) return;
    if (_suppressed.contains(attempt.original.toLowerCase())) return;

    _applying = true;
    try {
      final text = this.text;
      final start = attempt.replaceStart.clamp(0, text.length);
      final end = attempt.replaceEnd.clamp(start, text.length);
      if (text.substring(start, end) != attempt.original) return;

      final next = text.replaceRange(start, end, attempt.corrected);
      final delta = attempt.corrected.length - attempt.original.length;
      final caret = (caretAfter + delta).clamp(0, next.length);

      _mark = AutocorrectMark(
        start: start,
        end: start + attempt.corrected.length,
        original: attempt.original,
        corrected: attempt.corrected,
        createdAt: DateTime.now(),
      );
      _fade = privetLowResource ? 0 : 1;
      _backspaceUndoArmed = true;
      _undoCaret = caret;
      value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: caret),
      );

      _ttl?.cancel();
      _undoArmTtl?.cancel();
      _fadeCtrl?.stop();
      if (!privetLowResource && _fadeCtrl != null) {
        _fadeCtrl!.duration = const Duration(milliseconds: 2000);
        _fadeCtrl!.forward(from: 0);
      } else {
        _fade = 0;
      }
      _undoArmTtl = Timer(const Duration(seconds: 3), _disarmBackspaceUndo);
      _ttl = Timer(const Duration(seconds: 8), () {
        if (_mark != null) {
          _mark = null;
          _fade = 0;
          _disarmBackspaceUndo();
          notifyListeners();
          refreshSpelling();
        }
      });
    } finally {
      _applying = false;
    }
    refreshSpelling();
  }

  bool tryUndoWithBackspace() {
    if (!_backspaceUndoArmed) return false;
    final m = _mark;
    if (m == null) {
      _disarmBackspaceUndo();
      return false;
    }
    final sel = selection;
    if (!sel.isValid || !sel.isCollapsed) return false;
    if (sel.baseOffset != _undoCaret) {
      _disarmBackspaceUndo();
      return false;
    }

    final text = this.text;
    if (m.end > text.length ||
        m.start < 0 ||
        text.substring(m.start, m.end) != m.corrected) {
      clearMarks();
      return false;
    }

    final caretAfterWord = _undoCaret == m.end + 1;
    final ok = _revertMark(m, caretAfterWord: caretAfterWord);
    if (ok) refreshSpelling();
    return ok;
  }

  bool _revertMark(AutocorrectMark m, {required bool caretAfterWord}) {
    _suppressed.add(m.original.toLowerCase());
    _applying = true;
    try {
      final text = this.text;
      final next = text.replaceRange(m.start, m.end, m.original);
      final caret = caretAfterWord
          ? (m.start + m.original.length + 1).clamp(0, next.length)
          : (m.start + m.original.length).clamp(0, next.length);
      _ttl?.cancel();
      _fadeCtrl?.stop();
      _mark = null;
      _fade = 0;
      _disarmBackspaceUndo();
      value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: caret),
      );
    } finally {
      _applying = false;
    }
    return true;
  }

  void syncAfterEdit() {
    if (_applying) return;

    if (_backspaceUndoArmed) {
      final sel = selection;
      if (!sel.isValid ||
          !sel.isCollapsed ||
          sel.baseOffset != _undoCaret) {
        _disarmBackspaceUndo();
      }
    }

    final t = value.text;
    if (_suppressed.isNotEmpty) {
      final lower = t.toLowerCase();
      _suppressed.removeWhere((s) => !_hasWholeWord(lower, s));
    }

    final m = _mark;
    if (m != null) {
      if (m.end > t.length ||
          m.start < 0 ||
          t.substring(m.start, m.end) != m.corrected) {
        _suppressed.add(m.original.toLowerCase());
        _ttl?.cancel();
        _fadeCtrl?.stop();
        _mark = null;
        _fade = 0;
        _disarmBackspaceUndo();
      }
    }
    refreshSpelling();
  }

  static bool _hasWholeWord(String haystackLower, String wordLower) {
    if (wordLower.isEmpty) return false;
    var from = 0;
    while (true) {
      final i = haystackLower.indexOf(wordLower, from);
      if (i < 0) return false;
      final beforeOk =
          i == 0 || !_isWordCharCode(haystackLower.codeUnitAt(i - 1));
      final after = i + wordLower.length;
      final afterOk = after >= haystackLower.length ||
          !_isWordCharCode(haystackLower.codeUnitAt(after));
      if (beforeOk && afterOk) return true;
      from = i + 1;
    }
  }

  static bool _isWordCharCode(int c) {
    final isLower = c >= 97 && c <= 122;
    final isUpper = c >= 65 && c <= 90;
    final isDigit = c >= 48 && c <= 57;
    return isLower || isUpper || isDigit || c == 39;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final t = text;
    final m = _mark;
    final issues = _issues;
    final hovered = _hoveredIssue;
    final runs = _formatRuns;

    if (m == null && issues.isEmpty && runs.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    // Collect styled ranges: autocorrect flash wins over hover / underline.
    final cuts = <int>{0, t.length};
    if (m != null && m.start >= 0 && m.end <= t.length && m.start < m.end) {
      cuts.add(m.start);
      cuts.add(m.end);
    }
    for (final issue in issues) {
      if (issue.start >= 0 && issue.end <= t.length && issue.start < issue.end) {
        cuts.add(issue.start);
        cuts.add(issue.end);
      }
    }
    for (final r in runs) {
      if (r.start < 0 || r.end > t.length || r.start >= r.end) continue;
      cuts.add(r.start);
      cuts.add(r.end);
    }
    final points = cuts.toList()..sort();
    final children = <InlineSpan>[];
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i];
      final b = points[i + 1];
      if (a >= b) continue;
      final slice = t.substring(a, b);
      var sliceStyle = base;
      // Rich-text format runs first (flash / spell below can override).
      for (final r in runs) {
        if (r.start <= a && r.end >= b) {
          sliceStyle = r.format.toTextStyle(sliceStyle);
          break;
        }
      }
      if (m != null && a >= m.start && b <= m.end) {
        final alpha = (0.14 + 0.36 * _fade).clamp(0.14, 0.5);
        sliceStyle = sliceStyle.copyWith(
          backgroundColor: PrivetTheme.signal.withValues(alpha: alpha),
          color: PrivetTheme.paper,
          fontWeight: FontWeight.w600,
        );
      } else {
        SpellIssue? issue;
        for (final e in issues) {
          if (a >= e.start && b <= e.end) {
            issue = e;
            break;
          }
        }
        if (issue != null) {
          final isHovered =
              hovered != null &&
              issue.start == hovered.start &&
              issue.end == hovered.end;
          sliceStyle = sliceStyle.copyWith(
            decoration: TextDecoration.underline,
            decorationColor: const Color(0xFFE35D6A),
            decorationStyle: TextDecorationStyle.wavy,
            decorationThickness: 1.6,
            backgroundColor: isHovered
                ? const Color(0xFF5B9BD5).withValues(alpha: 0.38)
                : null,
          );
        }
      }
      children.add(TextSpan(style: sliceStyle, text: slice));
    }
    return TextSpan(style: base, children: children);
  }

  @override
  void dispose() {
    _ttl?.cancel();
    _undoArmTtl?.cancel();
    _fadeCtrl?.dispose();
    _fadeCtrl = null;
    super.dispose();
  }
}
