/// Server timestamps are UTC wall-clock strings, usually without a zone marker
/// (`YYYY-MM-DD HH:MM:SS` or `YYYY-MM-DDTHH:MM:SS`). Dart's [DateTime.tryParse]
/// treats unmarked strings as *local*, which makes non-UTC users see UTC times.
///
/// Always parse with this helper, then format via [DateTime.toLocal].
DateTime? parseServerUtc(dynamic value) {
  if (value == null) return null;
  var s = '$value'.trim();
  if (s.isEmpty) return null;
  s = s.replaceFirst(' ', 'T');
  // Already zoned (Z or ±HH:MM / ±HHMM).
  if (s.endsWith('Z') ||
      s.endsWith('z') ||
      RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s)) {
    return DateTime.tryParse(s);
  }
  return DateTime.tryParse('${s}Z');
}
