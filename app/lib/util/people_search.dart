import '../models.dart';

/// Case-insensitive people filter ranked for typeahead.
///
/// Prefer exact handle, then handle/display-name prefixes, then substrings.
List<PrivetUser> filterPeople(List<PrivetUser> directory, String rawQuery) {
  final q = normalizePeopleQuery(rawQuery);
  if (q.isEmpty) return List<PrivetUser>.of(directory);

  final scored = <({PrivetUser user, int score})>[];
  for (final u in directory) {
    final score = peopleMatchScore(u, q);
    if (score >= 0) scored.add((user: u, score: score));
  }
  scored.sort((a, b) {
    final byScore = a.score.compareTo(b.score);
    if (byScore != 0) return byScore;
    return a.user.displayName.toLowerCase().compareTo(
      b.user.displayName.toLowerCase(),
    );
  });
  return scored.map((e) => e.user).toList();
}

String normalizePeopleQuery(String raw) {
  var q = raw.trim().toLowerCase();
  if (q.startsWith('@')) q = q.substring(1).trim();
  return q;
}

/// Lower is better. Returns `-1` when [user] does not match [query].
int peopleMatchScore(PrivetUser user, String query) {
  if (query.isEmpty) return 0;
  final handle = user.handle.toLowerCase();
  final name = user.displayName.toLowerCase();
  if (handle == query) return 0;
  if (handle.startsWith(query)) return 1;
  if (name.startsWith(query)) return 2;
  if (handle.contains(query)) return 3;
  if (name.contains(query)) return 4;
  // Multi-word display names: match any word prefix ("lin" → "Alex Linux").
  for (final part in name.split(RegExp(r'[\s_\-]+'))) {
    if (part.startsWith(query)) return 2;
    if (part.contains(query)) return 4;
  }
  return -1;
}

/// True when [raw] is an invite link rather than a typed name/handle query.
bool looksLikeInviteUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return false;
  final uri = Uri.tryParse(text);
  if (uri != null &&
      uri.hasScheme &&
      (uri.queryParameters['invite']?.trim().isNotEmpty ?? false)) {
    return true;
  }
  return RegExp(r'[?&]invite=', caseSensitive: false).hasMatch(text);
}
