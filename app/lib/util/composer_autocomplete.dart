import 'emoticon_expand.dart';

/// One composer typeahead row.
class ComposerSuggestion {
  const ComposerSuggestion({
    required this.label,
    required this.insert,
    this.detail,
  });

  /// Primary label, e.g. `(smile)` or `# summarize`.
  final String label;

  /// Text written over the matched token when accepted.
  final String insert;

  /// Optional secondary text (emoji glyph, short hint).
  final String? detail;
}

/// Active autocomplete session for the composer caret.
class ComposerAutocomplete {
  const ComposerAutocomplete({
    required this.replaceStart,
    required this.replaceEnd,
    required this.suggestions,
  });

  final int replaceStart;
  final int replaceEnd;
  final List<ComposerSuggestion> suggestions;
}

const _aiCommands = <(String, String)>[
  ('# summarize', 'Unread messages summary (shared)'),
  ('# summarize 40', 'Last 40 messages (shared)'),
  ('# help', 'Show AI help'),
  ('#me summarize', 'Unread summary (private)'),
  ('#me ', 'Private question…'),
  ('# ', 'Shared question…'),
];

/// Returns up to [limit] suggestions for [text] at caret [cursor], or null.
ComposerAutocomplete? matchComposerAutocomplete(
  String text,
  int cursor, {
  int limit = 8,
  bool aiEnabled = true,
}) {
  if (cursor < 0 || cursor > text.length) return null;

  final parenthetical = _matchParenthetical(text, cursor, limit: limit);
  if (parenthetical != null) return parenthetical;

  if (aiEnabled) {
    final ai = _matchAi(text, cursor, limit: limit);
    if (ai != null) return ai;
  }

  return null;
}

ComposerAutocomplete? _matchParenthetical(
  String text,
  int cursor, {
  required int limit,
}) {
  // Token: `(partial` with no closing `)` yet. Require ≥1 letter after `(`.
  var i = cursor - 1;
  while (i >= 0) {
    final ch = text[i];
    if (ch == ')') return null;
    if (ch == '(') break;
    if (!_isShortcodeChar(ch)) return null;
    i--;
  }
  if (i < 0 || text[i] != '(') return null;
  final token = text.substring(i, cursor);
  if (token.length < 2) return null; // just `(`
  final query = token.toLowerCase();

  final hits = <ComposerSuggestion>[];
  for (final entry in emoticonParenthetical) {
    final code = entry.$1;
    if (!code.toLowerCase().startsWith(query)) continue;
    hits.add(
      ComposerSuggestion(label: code, insert: '${entry.$2} ', detail: entry.$2),
    );
    if (hits.length >= limit) break;
  }
  if (hits.isEmpty) return null;
  return ComposerAutocomplete(
    replaceStart: i,
    replaceEnd: cursor,
    suggestions: hits,
  );
}

ComposerAutocomplete? _matchAi(
  String text,
  int cursor, {
  required int limit,
}) {
  // First line only — AI commands are whole-composer `# …` lines.
  if (text.lastIndexOf('\n', cursor <= 0 ? 0 : cursor - 1) >= 0) return null;

  final prefix = text.substring(0, cursor);
  if (!prefix.startsWith('#')) return null;
  final lower = prefix.toLowerCase();

  final hits = <ComposerSuggestion>[];
  for (final entry in _aiCommands) {
    final cmd = entry.$1;
    if (!cmd.toLowerCase().startsWith(lower)) continue;
    hits.add(
      ComposerSuggestion(
        label: cmd.trimRight(),
        insert: cmd.endsWith(' ') ? cmd : '$cmd ',
        detail: entry.$2,
      ),
    );
    if (hits.length >= limit) break;
  }
  if (hits.isEmpty) return null;
  return ComposerAutocomplete(
    replaceStart: 0,
    replaceEnd: cursor,
    suggestions: hits,
  );
}

bool _isShortcodeChar(String ch) {
  if (ch.length != 1) return false;
  final c = ch.codeUnitAt(0);
  final isLower = c >= 97 && c <= 122;
  final isUpper = c >= 65 && c <= 90;
  final isDigit = c >= 48 && c <= 57;
  return isLower || isUpper || isDigit;
}
