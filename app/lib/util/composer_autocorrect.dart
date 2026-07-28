import 'package:flutter/services.dart' show rootBundle;

/// Result of a word-boundary autocorrect check.
class AutocorrectAttempt {
  const AutocorrectAttempt({
    required this.replaceStart,
    required this.replaceEnd,
    required this.original,
    required this.corrected,
  });

  final int replaceStart;
  final int replaceEnd;
  final String original;
  final String corrected;
}

/// English composer autocorrect — Teams-style: conservative and high-confidence.
///
/// Priority:
/// 1. Curated typo map (common misspellings)
/// 2. Unique edit-distance-1 for unknown words (length ≥ 4)
/// 3. Clear frequency winner among multiple edit-1 hits (length ≥ 5)
///
/// Never touches contractions (`what's`), chat slang (`bro`), or short ambiguous
/// substitutions (`bro`→`pro`).
class ComposerAutocorrectDictionary {
  ComposerAutocorrectDictionary._();

  static final ComposerAutocorrectDictionary instance =
      ComposerAutocorrectDictionary._();

  static const assetPath = 'assets/dictionaries/en_words.txt';

  /// Words below this rank are treated as intentional vocabulary.
  static const int _knownRankCutoff = 15000;

  Map<String, int>? _rank;
  Future<void>? _loading;

  bool get isReady => _rank != null;

  /// True once the curated map can run (always), and ideally after dict load.
  bool get canCorrect => true;

  /// Loads the word list once. Safe to call repeatedly.
  Future<void> ensureLoaded() {
    if (_rank != null) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final rank = <String, int>{};
      var i = 0;
      for (final line in raw.split('\n')) {
        final w = line.trim().toLowerCase();
        if (w.isEmpty) continue;
        rank.putIfAbsent(w, () => i++);
      }
      _rank = rank;
    } catch (_) {
      // Curated map still works without the frequency list.
      _rank = {};
    }
  }

  /// For tests — inject a ready dictionary without asset I/O.
  /// [words] order is frequency order (first = most common).
  void loadFromWords(Iterable<String> words) {
    final rank = <String, int>{};
    var i = 0;
    for (final w in words) {
      final lower = w.toLowerCase();
      if (lower.isEmpty) continue;
      rank.putIfAbsent(lower, () => i++);
    }
    _rank = rank;
    _loading = Future<void>.value();
  }

  bool contains(String lower) => _rank?.containsKey(lower) ?? false;

  /// Returns a high-confidence correction, or null.
  String? correctionFor(String token) {
    if (!_isCandidateToken(token)) return null;

    final lower = token.toLowerCase();

    // Contractions / possessives — never strip or rewrite.
    if (lower.contains("'") || lower.contains('\u2019')) return null;

    // Bare contraction typo → apostrophe form (isnt → isn't, arent → aren't).
    final bareContracted = _apostropheForms[lower];
    if (bareContracted != null) {
      return _applyCasing(token, bareContracted);
    }

    // Tiny / solid words we never rewrite.
    if (_alwaysValidWords.contains(lower)) return null;

    // Chat slang / intentional informal — leave alone.
    if (_protectedWords.contains(lower)) return null;

    // Curated map wins first (works even before the word list loads).
    final mapped = _knownTypos[lower];
    if (mapped != null) return _applyCasing(token, mapped);

    final rank = _rank;
    if (rank == null || rank.isEmpty) return null;

    // Need at least 3 letters for edit-1 (teh/bhut/adn).
    if (lower.length < 3) return null;

    final selfRank = rank[lower];
    // Common known words are intentional.
    if (selfRank != null && selfRank < _knownRankCutoff) return null;

    // Dedupe: the same candidate can be reached via multiple edits
    // (e.g. sugestion → suggestion by inserting 'g' at index 2 or 3).
    final seen = <String>{};
    final hits = <(int, String)>[];
    for (final c in _editDistance1(lower)) {
      if (!seen.add(c)) continue;
      final r = rank[c];
      if (r != null) hits.add((r, c));
    }
    if (hits.isNotEmpty) {
      hits.sort((a, b) => a.$1.compareTo(b.$1));

      final best = hits.first;

      // Rare dictionary junk may only upgrade to a much commoner word.
      if (selfRank == null || selfRank >= best.$1 * 8 + 100) {
        // Unique edit-1 — accept for length ≥ 3 when target is reasonably common.
        if (hits.length == 1) {
          if (best.$1 < 8000) return _applyCasing(token, best.$2);
        } else {
          // Multiple candidates: need a clear frequency winner (Teams-like).
          final second = hits[1];
          if (_isClearWinner(best.$1, second.$1, wordLen: lower.length)) {
            return _applyCasing(token, best.$2);
          }
        }
      }
    }

    // Missing space: correctthings → correct things (Teams does this).
    final split = _missingSpaceCorrection(lower);
    if (split != null) return _applyCasingToPhrase(token, split);

    return null;
  }

  /// High-confidence missing-space fix, or null.
  String? _missingSpaceCorrection(String lower) {
    if (lower.length < 8) return null;
    final splits = _findWordSplits(lower);
    if (splits.isEmpty) return null;
    if (splits.length == 1) {
      // Single clean cut into two known words.
      return '${splits.first.$2} ${splits.first.$3}';
    }
    final best = splits[0];
    final second = splits[1];
    // Clear frequency winner among possible cuts.
    if (best.$1 <= 5000 && second.$1 >= best.$1 * 2 + 300) {
      return '${best.$2} ${best.$3}';
    }
    if (best.$1 < 3500 && second.$1 >= best.$1 + 2000) {
      return '${best.$2} ${best.$3}';
    }
    final good = splits.where((s) => s.$1 < 5000).toList();
    if (good.length == 1) return '${good.first.$2} ${good.first.$3}';
    return null;
  }

  /// Ranked splits `(score, left, right)` best-first. score = rankL + rankR.
  List<(int, String, String)> _findWordSplits(String lower) {
    final rank = _rank;
    if (rank == null || rank.isEmpty || lower.length < 6) return const [];
    const minPart = 3;
    const maxPartRank = 10000;
    final out = <(int, String, String)>[];
    for (var i = minPart; i <= lower.length - minPart; i++) {
      final left = lower.substring(0, i);
      final right = lower.substring(i);
      final rl = rank[left];
      final rr = rank[right];
      if (rl == null || rr == null) continue;
      if (rl >= maxPartRank || rr >= maxPartRank) continue;
      out.add((rl + rr, left, right));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  bool _isClearWinner(int bestRank, int secondRank, {required int wordLen}) {
    // Dominant common word (the/and/but/just/…).
    if (bestRank <= 80 && secondRank >= bestRank + 150) return true;
    if (bestRank <= 300 && secondRank >= bestRank * 4 && secondRank >= bestRank + 80) {
      return true;
    }
    // Longer typos: slightly looser gap is OK.
    if (wordLen >= 5 &&
        bestRank < 2500 &&
        secondRank >= bestRank * 3 &&
        secondRank >= bestRank + 60) {
      return true;
    }
    // Short words need a bigger gap so "bro"/"pro"-style swaps stay out.
    // When bestRank is 0 (e.g. "the"), require a real gap — not "anything".
    if (wordLen <= 3) {
      final minSecond = bestRank <= 0 ? 200 : (bestRank * 8).clamp(bestRank + 100, 1 << 30);
      return bestRank <= 50 && secondRank >= minSecond;
    }
    return false;
  }

  /// If [cursor] sits just after a word-closing delimiter, try correcting
  /// the word that was just finished.
  AutocorrectAttempt? tryAutocorrect(String text, int cursor) {
    if (cursor < 2 || cursor > text.length) return null;
    final delim = text[cursor - 1];
    if (!_isWordDelimiter(delim)) return null;

    var end = cursor - 1;
    var start = end;
    while (start > 0 && _isWordChar(text[start - 1])) {
      start--;
    }
    if (start >= end) return null;
    final original = text.substring(start, end);
    final corrected = correctionFor(original);
    if (corrected == null || corrected == original) return null;
    return AutocorrectAttempt(
      replaceStart: start,
      replaceEnd: end,
      original: original,
      corrected: corrected,
    );
  }

  /// Teams-style: find misspelled words with up to 3 suggestions each.
  ///
  /// Only **finished** words are checked (must be followed by a delimiter such
  /// as space/punctuation) — never underline the word currently being typed.
  List<SpellIssue> findSpellIssues(String text) {
    final rank = _rank;
    if (rank == null || rank.isEmpty) return const [];

    final issues = <SpellIssue>[];
    var i = 0;
    while (i < text.length) {
      if (!_isWordChar(text[i])) {
        i++;
        continue;
      }
      final start = i;
      while (i < text.length && _isWordChar(text[i])) {
        i++;
      }
      // Still typing this token (no space/punct after it yet).
      if (i >= text.length || !_isWordDelimiter(text[i])) continue;

      final word = text.substring(start, i);
      if (!_shouldUnderline(word)) continue;
      final suggestions = suggestionsFor(word, limit: 3);
      // No point underlining if we have nothing useful to offer (Teams always
      // pairs red squiggles with at least one guess).
      if (suggestions.isEmpty) continue;
      issues.add(
        SpellIssue(
          start: start,
          end: i,
          word: word,
          suggestions: suggestions,
        ),
      );
    }
    return issues;
  }

  /// Whether [token] should get a red spelling underline.
  bool _shouldUnderline(String token) {
    if (token.length < 2) return false;
    if (token.startsWith('@') || token.startsWith('#')) return false;
    final lower = token.toLowerCase();
    if (lower.startsWith('http') || lower.contains('://')) return false;
    if (_alwaysValidWords.contains(lower)) return false;

    final key = lower.replaceAll('\u2019', "'");
    final bare = key.replaceAll("'", '');
    if (bare.length < 2) return false;

    // Known contractions: "isn't" / "aren't" are valid; "isnt" / "arent" are not.
    // Checked before [_protectedWords] — bare forms are protected from autocorrect
    // but still get Teams-style underlines + suggestions.
    final contracted = _apostropheForms[bare];
    if (contracted != null) {
      return key != contracted.toLowerCase();
    }

    if (_protectedWords.contains(lower)) return false;

    // ALL-CAPS acronyms.
    var letters = 0;
    var allUpper = true;
    var hasDigit = false;
    for (var i = 0; i < token.length; i++) {
      final c = token.codeUnitAt(i);
      if (c >= 48 && c <= 57) hasDigit = true;
      if (c >= 65 && c <= 90) {
        letters++;
      } else if (c >= 97 && c <= 122) {
        letters++;
        allUpper = false;
      }
    }
    if (hasDigit) return false;
    if (letters >= 2 && allUpper) return false;

    // Known common vocabulary — not underlined.
    final r = rankLookup(key) ?? rankLookup(bare);
    if (r != null && r < _underlineKnownCutoff) return false;

    return true;
  }

  int? rankLookup(String lower) => _rank?[lower];

  /// Top spelling suggestions for a misspelled [token] (Teams shows ~3).
  List<String> suggestionsFor(String token, {int limit = 3}) {
    final rank = _rank;
    if (rank == null || rank.isEmpty || limit <= 0) return const [];

    final lower = token.toLowerCase().replaceAll('\u2019', "'");
    final bare = lower.replaceAll("'", '');
    if (bare.length < 2) return const [];

    final out = <String>[];
    final seen = <String>{};

    void addSuggestion(String raw) {
      final suggestion = raw.contains(' ')
          ? _applyCasingToPhrase(token, raw)
          : _applyCasing(token, raw);
      final key = suggestion.toLowerCase();
      if (!seen.add(key)) return;
      if (key == lower) return;
      out.add(suggestion);
    }

    // Missing-space splits first (correctthings → correct things).
    for (final split in _findWordSplits(bare)) {
      addSuggestion('${split.$2} ${split.$3}');
      if (out.length >= limit) return out;
    }

    // Contraction-aware shortcuts (cn't → can't).
    final forced = _contractionHints[bare];
    final scored = <(int dist, int freq, String word)>[];

    if (forced != null) {
      for (var i = 0; i < forced.length; i++) {
        scored.add((0, i, forced[i]));
      }
    }

    final minLen = (bare.length - 2).clamp(1, 40);
    final maxLen = bare.length + 2;
    for (final entry in rank.entries) {
      final w = entry.key;
      if (w.length < minLen || w.length > maxLen) continue;
      final d = _levenshtein(bare, w, maxDist: 2);
      if (d < 1 || d > 2) continue;
      scored.add((d, entry.value, w));
    }

    scored.sort((a, b) {
      final byDist = a.$1.compareTo(b.$1);
      if (byDist != 0) return byDist;
      return a.$2.compareTo(b.$2);
    });

    for (final hit in scored) {
      var suggestion = hit.$3;
      if (lower.contains("'") || forced != null) {
        suggestion = _apostropheForms[suggestion] ?? suggestion;
      }
      addSuggestion(suggestion);
      if (out.length >= limit) break;
    }

    // Gibberish fallback (Teams still offers guesses): common words that share
    // a leading prefix — e.g. asdfadsfasdf → ask / asia / aside.
    if (out.length < limit && bare.length >= 4) {
      for (final plen in const [3, 2]) {
        if (bare.length < plen) continue;
        final pref = bare.substring(0, plen);
        final prefixHits = <(int, String)>[];
        for (final entry in rank.entries) {
          final w = entry.key;
          if (w.length < plen || w.length > bare.length + 2) continue;
          if (!w.startsWith(pref)) continue;
          // Prefer words not vastly shorter than a short typo.
          if (bare.length <= 6 && w.length < plen) continue;
          prefixHits.add((entry.value, w));
        }
        if (prefixHits.isEmpty) continue;
        prefixHits.sort((a, b) => a.$1.compareTo(b.$1));
        for (final hit in prefixHits) {
          addSuggestion(hit.$2);
          if (out.length >= limit) return out;
        }
        if (out.isNotEmpty) break;
      }
    }

    return out;
  }
}

/// A misspelled span with Teams-style replacement suggestions.
class SpellIssue {
  const SpellIssue({
    required this.start,
    required this.end,
    required this.word,
    required this.suggestions,
  });

  final int start;
  final int end;
  final String word;
  final List<String> suggestions;

  bool containsOffset(int offset) => offset >= start && offset <= end;
}

/// Rare dictionary junk above this rank is still underlined as a typo.
const int _underlineKnownCutoff = 10000;

/// Tiny function words missing from the frequency list (len &lt; 3 filter).
const _alwaysValidWords = <String>{
  'a', 'i', 'an', 'as', 'at', 'be', 'by', 'do', 'go', 'he', 'if', 'in', 'is',
  'it', 'me', 'my', 'no', 'of', 'ok', 'on', 'or', 'so', 'to', 'up', 'us', 'we',
  "i'm", "i've", "i'd", "i'll", "it's",
  // Solid compounds missing from the frequency list — do not split/underline.
  'cannot',
};

/// Bare stem → preferred contraction suggestions.
const _contractionHints = <String, List<String>>{
  'cnt': ["can't", 'can', 'cent'],
  'cant': ["can't", 'can', 'cant'],
  'wnt': ["won't", 'want', 'went'],
  'wont': ["won't", 'want', 'wont'],
  'dnt': ["don't", 'didnt', 'dent'],
  'dont': ["don't", 'dont'],
  'isnt': ["isn't", 'isnt'],
  'arent': ["aren't", 'arent'],
  'wasnt': ["wasn't", 'wasnt'],
  'werent': ["weren't", 'werent'],
  'couldnt': ["couldn't", 'couldnt'],
  'wouldnt': ["wouldn't", 'wouldnt'],
  'shouldnt': ["shouldn't", 'shouldnt'],
  'havent': ["haven't", 'havent'],
  'hasnt': ["hasn't", 'hasnt'],
  'hadnt': ["hadn't", 'hadnt'],
  'doesnt': ["doesn't", 'doesnt'],
  'didnt': ["didn't", 'didnt'],
};

const _apostropheForms = <String, String>{
  'cant': "can't",
  'wont': "won't",
  'dont': "don't",
  'isnt': "isn't",
  'arent': "aren't",
  'wasnt': "wasn't",
  'werent': "weren't",
  'couldnt': "couldn't",
  'wouldnt': "wouldn't",
  'shouldnt': "shouldn't",
  'havent': "haven't",
  'hasnt': "hasn't",
  'hadnt': "hadn't",
  'doesnt': "doesn't",
  'didnt': "didn't",
  'im': "I'm",
  'ive': "I've",
  'id': "I'd",
  'ill': "I'll",
  'youre': "you're",
  'theyre': "they're",
  'weve': "we've",
  'hes': "he's",
  'shes': "she's",
};

/// Levenshtein distance capped at [maxDist] (+1 means "over").
int _levenshtein(String a, String b, {required int maxDist}) {
  if (a == b) return 0;
  if ((a.length - b.length).abs() > maxDist) return maxDist + 1;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var prev = List<int>.generate(b.length + 1, (i) => i);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    var rowMin = curr[0];
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final v = prev[j - 1] + cost;
      final del = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      var best = v < del ? v : del;
      if (ins < best) best = ins;
      curr[j] = best;
      if (best < rowMin) rowMin = best;
    }
    if (rowMin > maxDist) return maxDist + 1;
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length];
}

/// Apostrophe is NOT a delimiter — contractions like what's stay one token.
bool _isWordDelimiter(String ch) {
  if (ch.length != 1) return false;
  return ch == ' ' ||
      ch == '\n' ||
      ch == '\t' ||
      ch == '.' ||
      ch == ',' ||
      ch == '!' ||
      ch == '?' ||
      ch == ';' ||
      ch == ':' ||
      ch == ')' ||
      ch == ']' ||
      ch == '"' ||
      ch == '\u201C' ||
      ch == '\u201D';
}

bool _isWordChar(String ch) {
  if (ch.length != 1) return false;
  final c = ch.codeUnitAt(0);
  final isLower = c >= 97 && c <= 122;
  final isUpper = c >= 65 && c <= 90;
  final isDigit = c >= 48 && c <= 57;
  return isLower || isUpper || isDigit || ch == "'" || ch == '\u2019';
}

bool _isCandidateToken(String token) {
  if (token.length < 3) return false;
  if (token.startsWith('@') || token.startsWith('#')) return false;
  final lower = token.toLowerCase();
  if (lower.startsWith('http') || lower.contains('://')) return false;
  var letters = 0;
  var hasUpper = false;
  var allUpperLetters = true;
  for (var i = 0; i < token.length; i++) {
    final c = token.codeUnitAt(i);
    if (c >= 48 && c <= 57) return false;
    final isUpper = c >= 65 && c <= 90;
    final isLower = c >= 97 && c <= 122;
    if (isUpper || isLower) {
      letters++;
      if (isUpper) {
        hasUpper = true;
      } else {
        allUpperLetters = false;
      }
    } else if (token[i] != "'" && token[i] != '\u2019') {
      return false;
    }
  }
  if (letters >= 3 && hasUpper && allUpperLetters) return false;
  return letters >= 3;
}

Iterable<String> _editDistance1(String word) sync* {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz';
  final n = word.length;

  for (var i = 0; i < n; i++) {
    yield word.substring(0, i) + word.substring(i + 1);
  }
  for (var i = 0; i < n - 1; i++) {
    yield word.substring(0, i) +
        word[i + 1] +
        word[i] +
        word.substring(i + 2);
  }
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < alphabet.length; j++) {
      final ch = alphabet[j];
      if (ch == word[i]) continue;
      yield word.substring(0, i) + ch + word.substring(i + 1);
    }
  }
  for (var i = 0; i <= n; i++) {
    for (var j = 0; j < alphabet.length; j++) {
      yield word.substring(0, i) + alphabet[j] + word.substring(i);
    }
  }
}

String _applyCasing(String original, String corrected) {
  if (original.isEmpty || corrected.isEmpty) return corrected;
  final firstUpper = original[0].toUpperCase() == original[0] &&
      original[0].toLowerCase() != original[0];
  final rest = original.length == 1 ? '' : original.substring(1);
  final restLower = rest == rest.toLowerCase();
  if (firstUpper && restLower) {
    return corrected[0].toUpperCase() +
        (corrected.length > 1 ? corrected.substring(1).toLowerCase() : '');
  }
  return corrected;
}

/// Like [_applyCasing] but keeps later words lower for "Correctthings" → "Correct things".
String _applyCasingToPhrase(String original, String corrected) {
  if (!corrected.contains(' ')) return _applyCasing(original, corrected);
  final parts = corrected.split(' ');
  final first = _applyCasing(original, parts.first);
  return [first, ...parts.skip(1)].join(' ');
}

/// High-confidence misspellings.
const _knownTypos = <String, String>{
  'teh': 'the',
  'hte': 'the',
  'adn': 'and',
  'nad': 'and',
  'taht': 'that',
  'thta': 'that',
  'htat': 'that',
  'thier': 'their',
  'recieve': 'receive',
  'recieved': 'received',
  'beleive': 'believe',
  'beleived': 'believed',
  'becuase': 'because',
  'becasue': 'because',
  'becouse': 'because',
  'wrold': 'world',
  'whiel': 'while',
  'wiht': 'with',
  'iwth': 'with',
  'waht': 'what',
  'whta': 'what',
  'hwat': 'what',
  'whcih': 'which',
  'wich': 'which',
  'jsut': 'just',
  'juts': 'just',
  'untill': 'until',
  'seperate': 'separate',
  'definately': 'definitely',
  'definatly': 'definitely',
  'occured': 'occurred',
  'accomodate': 'accommodate',
  'tommorow': 'tomorrow',
  'tommorrow': 'tomorrow',
  'freind': 'friend',
  'freinds': 'friends',
  'peice': 'piece',
  'wierd': 'weird',
  'goverment': 'government',
  'enviroment': 'environment',
  'rember': 'remember',
  'remeber': 'remember',
  'interupt': 'interrupt',
  'succesful': 'successful',
  'successfull': 'successful',
  'arguement': 'argument',
  'truely': 'truly',
  'neccessary': 'necessary',
  'occassion': 'occasion',
  'helllo': 'hello',
  'heloo': 'hello',
  'langauge': 'language',
  'refering': 'referring',
  'begining': 'beginning',
  'exmaple': 'example',
  'exmaples': 'examples',
  'probaly': 'probably',
  'probly': 'probably',
  'realy': 'really',
  'relaly': 'really',
  'correcton': 'correction',
  'corection': 'correction',
  'corrction': 'correction',
  'corrctin': 'correcting',
  'corrcting': 'correcting',
  'corecting': 'correcting',
  'corect': 'correct',
  'correect': 'correct',
  'smoe': 'some',
  'soem': 'some',
  'anyting': 'anything',
  'anyhting': 'anything',
  'nothign': 'nothing',
  'seemss': 'seems',
  'abot': 'about',
  'abuot': 'about',
  'agian': 'again',
  'bhut': 'but',
  'buth': 'but',
  'ubt': 'but',
  // Chat / short typos users actually type
  'wht': 'what',
  'wat': 'what',
  'heer': 'here',
  'herer': 'here',
  'heere': 'here',
  'gong': 'going',
  'goign': 'going',
  'oging': 'going',
  'wassap': 'wassup',
  'wasap': 'wassup',
  'wen': 'when',
  'whn': 'when',
  'wher': 'where',
  'whre': 'where',
  'hwo': 'how',
  'ohw': 'how',
  'becaus': 'because',
  'becaues': 'because',
  'yuo': 'you',
  'yuor': 'your',
  'yoru': 'your',
  'ahve': 'have',
  'tihs': 'this',
  'htis': 'this',
  'thsi': 'this',
  'frome': 'from',
};

/// Informal / chat words that must never be rewritten.
const _protectedWords = <String>{
  'bro',
  'bruh',
  'sis',
  'dude',
  'lol',
  'lmao',
  'lmfao',
  'omg',
  'omfg',
  'idk',
  'idc',
  'imo',
  'imho',
  'tbh',
  'tbf',
  'nvm',
  'smh',
  'afaik',
  'asap',
  'btw',
  'fyi',
  'ikr',
  'iykyk',
  'gg',
  'wp',
  'ez',
  'op',
  'pro',
  'noob',
  'nah',
  'yea',
  'yeah',
  'yep',
  'yup',
  'nope',
  'hey',
  'hi',
  'sup',
  'yo',
  'bae',
  'fam',
  'sus',
  'lit',
  'cap',
  'mid',
  'rn',
  'tho',
  'thru',
  'gonna',
  'wanna',
  'gotta',
  'kinda',
  'sorta',
  'outta',
  'lemme',
  'gimme',
  'dunno',
  'ain',
  'ok',
  'okay',
  'k',
  'kk',
  'pls',
  'plz',
  'thx',
  'ty',
  'np',
  'yw',
  'msg',
  'dm',
  'pm',
  'bc',
  'cuz',
  'cos',
  'cause',
  'whats',
  'dont',
  'cant',
  'wont',
  'isnt',
  'arent',
  'wasnt',
  'werent',
  'hasnt',
  'havent',
  'hadnt',
  'doesnt',
  'didnt',
  'couldnt',
  'wouldnt',
  'shouldnt',
  'im',
  'ive',
  'ill',
  'id',
  'youre',
  'theyre',
  'theyve',
  'weve',
  'hes',
  'shes',
  'its',
};
