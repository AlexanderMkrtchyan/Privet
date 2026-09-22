import 'dart:convert';
import 'dart:math';

/// CEFR ladder — A1 (beginner) to C2 (fluent / near-native).
enum CefrLevel { a1, a2, b1, b2, c1, c2 }

extension CefrLevelX on CefrLevel {
  String get code => name.toUpperCase();

  String get title => switch (this) {
        CefrLevel.a1 => 'Beginner',
        CefrLevel.a2 => 'Elementary',
        CefrLevel.b1 => 'Intermediate',
        CefrLevel.b2 => 'Upper-intermediate',
        CefrLevel.c1 => 'Advanced',
        CefrLevel.c2 => 'Fluent',
      };

  String get blurb => switch (this) {
        CefrLevel.a1 => 'Simple phrases about yourself and everyday needs.',
        CefrLevel.a2 => 'Short routine chats, basic past and future.',
        CefrLevel.b1 => 'Handles most chats; describes plans, opinions, stories.',
        CefrLevel.b2 => 'Clear, detailed, mostly accurate; argues a point.',
        CefrLevel.c1 => 'Flexible and precise; rare slips, rich vocabulary.',
        CefrLevel.c2 => 'Effortless and natural — native-like control.',
      };

  CefrLevel? get next =>
      index + 1 < CefrLevel.values.length ? CefrLevel.values[index + 1] : null;

  static CefrLevel? parse(Object? raw) {
    final s = raw?.toString().trim().toLowerCase() ?? '';
    for (final l in CefrLevel.values) {
      if (s == l.name) return l;
    }
    return null;
  }
}

/// Issue type ids the server prompt allows.
String trainerIssueTypeLabel(String type) => switch (type) {
      'tense' => 'Tense',
      'article' => 'Article',
      'preposition' => 'Preposition',
      'agreement' => 'Agreement',
      'word_order' => 'Word order',
      'word_choice' => 'Word choice',
      'spelling' => 'Spelling',
      'plural' => 'Plural',
      'punctuation' => 'Punctuation',
      'capitalization' => 'Capitals',
      'missing_word' => 'Missing word',
      'extra_word' => 'Extra word',
      _ => 'Other',
    };

class TrainerIssue {
  const TrainerIssue({
    required this.wrong,
    required this.right,
    required this.type,
    required this.major,
    required this.why,
    required this.example,
  });

  final String wrong;
  final String right;
  final String type;
  final bool major;
  final String why;
  final String example;

  static TrainerIssue? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final wrong = raw['wrong']?.toString() ?? '';
    final right = raw['right']?.toString() ?? '';
    if (wrong.trim().isEmpty && right.trim().isEmpty) return null;
    if (wrong.trim() == right.trim()) return null;
    return TrainerIssue(
      wrong: wrong,
      right: right,
      type: _normType(raw['type']),
      major: raw['severity']?.toString().toLowerCase() != 'minor',
      why: raw['why']?.toString().trim() ?? '',
      example: raw['example']?.toString().trim() ?? '',
    );
  }

  static String _normType(Object? raw) {
    final s = (raw?.toString() ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s-]+'), '_');
    const known = {
      'tense',
      'article',
      'preposition',
      'agreement',
      'word_order',
      'word_choice',
      'spelling',
      'plural',
      'punctuation',
      'capitalization',
      'missing_word',
      'extra_word',
    };
    return known.contains(s) ? s : 'other';
  }
}

/// One pre-send grammar check result.
class TrainerCheck {
  const TrainerCheck({
    required this.original,
    required this.corrected,
    required this.issues,
    this.natural = '',
    this.quip = '',
    this.cefr,
  });

  final String original;
  final String corrected;
  final List<TrainerIssue> issues;
  final String natural;
  final String quip;
  final CefrLevel? cefr;

  int get majorCount => issues.where((i) => i.major).length;
  int get minorCount => issues.length - majorCount;
  bool get hasMajor => majorCount > 0;

  /// Parse the model reply. Returns null when it is not the expected JSON.
  ///
  /// "Coach's version" is rebuilt by applying issue replacements to the
  /// original whenever possible — models often put a native rewrite in
  /// `corrected`, which belongs under `natural` instead.
  static TrainerCheck? parse(String original, String raw) {
    final map = decodeTrainerJson(raw);
    if (map == null) return null;
    if (!map.containsKey('issues') && !map.containsKey('corrected')) {
      return null;
    }
    final issues = <TrainerIssue>[];
    final list = map['issues'];
    if (list is List) {
      for (final item in list) {
        final issue = TrainerIssue.fromJson(item);
        if (issue != null) issues.add(issue);
      }
    }
    final modelCorrected = map['corrected']?.toString().trim() ?? '';
    var natural = map['natural']?.toString().trim() ?? '';
    final applied = applyTrainerFixes(original, issues);

    late final String corrected;
    if (issues.isEmpty) {
      corrected = original;
    } else if (applied != null) {
      corrected = applied;
      // Model put a freer rewrite in `corrected` — keep it as the native tip.
      if (modelCorrected.isNotEmpty &&
          !_sameLoose(modelCorrected, applied) &&
          !_sameLoose(modelCorrected, original) &&
          (natural.isEmpty || _sameLoose(natural, applied))) {
        natural = modelCorrected;
      }
    } else if (modelCorrected.isNotEmpty) {
      corrected = modelCorrected;
    } else {
      corrected = original;
    }

    return TrainerCheck(
      original: original,
      corrected: corrected,
      issues: issues,
      natural: _sameLoose(natural, corrected) || _sameLoose(natural, original)
          ? ''
          : natural,
      quip: map['quip']?.toString().trim() ?? '',
      cefr: CefrLevelX.parse(map['cefr']),
    );
  }

  static bool _sameLoose(String a, String b) {
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    return norm(a) == norm(b);
  }
}

/// Apply each issue's wrong→right edit to [original].
/// Returns null when a non-empty `wrong` span cannot be located.
String? applyTrainerFixes(String original, List<TrainerIssue> issues) {
  if (issues.isEmpty) return original;
  final actionable = [
    for (var i = 0; i < issues.length; i++)
      if (issues[i].wrong.trim().isNotEmpty) i,
  ];
  if (actionable.isEmpty) return original;
  final spans = trainerIssueSpans(original, issues);
  if (spans.length < actionable.length) return null;
  final ordered = [...spans]..sort((a, b) => b.start.compareTo(a.start));
  var out = original;
  for (final s in ordered) {
    out = out.replaceRange(s.start, s.end, issues[s.issue].right);
  }
  return out;
}

/// Where each issue's `wrong` text sits inside [text] (non-overlapping, in order).
List<({int start, int end, int issue})> trainerIssueSpans(
  String text,
  List<TrainerIssue> issues,
) {
  final found = <({int start, int end, int issue})>[];
  final lower = text.toLowerCase();
  final wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);
  bool isWord(int at) => at >= 0 && at < text.length && wordChar.hasMatch(text[at]);

  int? locate(String needle, {required bool exactCase, required bool whole}) {
    final hay = exactCase ? text : lower;
    final pin = exactCase ? needle : needle.toLowerCase();
    var from = 0;
    while (true) {
      final at = hay.indexOf(pin, from);
      if (at < 0) return null;
      final end = at + pin.length;
      final bounded = !whole ||
          ((!isWord(at) || !isWord(at - 1)) && (!isWord(end - 1) || !isWord(end)));
      final overlaps = found.any((s) => at < s.end && end > s.start);
      if (bounded && !overlaps) return at;
      from = at + 1;
    }
  }

  for (var i = 0; i < issues.length; i++) {
    final needle = issues[i].wrong.trim();
    if (needle.isEmpty) continue;
    // Prefer a whole-word, exact-case hit so "i" does not land inside "big".
    final at = locate(needle, exactCase: true, whole: true) ??
        locate(needle, exactCase: false, whole: true) ??
        locate(needle, exactCase: true, whole: false) ??
        locate(needle, exactCase: false, whole: false);
    if (at == null) continue;
    found.add((start: at, end: at + needle.length, issue: i));
  }
  found.sort((a, b) => a.start.compareTo(b.start));
  return found;
}

class TrainerDrill {
  const TrainerDrill({
    required this.prompt,
    required this.answer,
    this.tip = '',
  });

  final String prompt;
  final String answer;
  final String tip;

  Map<String, dynamic> toJson() => {'p': prompt, 'a': answer, 't': tip};

  static TrainerDrill? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final prompt = (raw['prompt'] ?? raw['p'])?.toString().trim() ?? '';
    final answer = (raw['answer'] ?? raw['a'])?.toString().trim() ?? '';
    if (prompt.isEmpty || answer.isEmpty) return null;
    return TrainerDrill(
      prompt: prompt,
      answer: answer,
      tip: (raw['tip'] ?? raw['t'])?.toString().trim() ?? '',
    );
  }
}

/// "Review my English level" result.
class TrainerLevelReport {
  const TrainerLevelReport({
    required this.level,
    required this.progress,
    required this.at,
    this.title = '',
    this.verdict = '',
    this.strengths = const [],
    this.weaknesses = const [],
    this.nextGoal = '',
    this.drills = const [],
  });

  final CefrLevel level;

  /// 0–100 through [level].
  final int progress;
  final DateTime at;
  final String title;
  final String verdict;
  final List<String> strengths;
  final List<String> weaknesses;
  final String nextGoal;
  final List<TrainerDrill> drills;

  /// Position on the whole A1–C2 ladder, 0–1.
  double get ladderPosition =>
      (level.index + progress.clamp(0, 100) / 100) / CefrLevel.values.length;

  static TrainerLevelReport? parse(String raw, {DateTime? at}) {
    final map = decodeTrainerJson(raw);
    if (map == null) return null;
    return fromJson(map, at: at);
  }

  static TrainerLevelReport? fromJson(Map map, {DateTime? at}) {
    final level = CefrLevelX.parse(map['level']);
    if (level == null) return null;
    final progress = switch (map['progress']) {
      final num n => n.round(),
      final String s => int.tryParse(s.trim()) ?? 50,
      _ => 50,
    };
    return TrainerLevelReport(
      level: level,
      progress: progress.clamp(0, 100),
      at: at ??
          DateTime.tryParse(map['at']?.toString() ?? '') ??
          DateTime.now(),
      title: map['title']?.toString().trim() ?? '',
      verdict: map['verdict']?.toString().trim() ?? '',
      strengths: _strings(map['strengths']),
      weaknesses: _strings(map['weaknesses']),
      nextGoal: map['nextGoal']?.toString().trim() ?? '',
      drills: [
        if (map['drills'] is List)
          for (final d in map['drills'] as List) ?TrainerDrill.fromJson(d),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'level': level.name,
        'progress': progress,
        'at': at.toIso8601String(),
        'title': title,
        'verdict': verdict,
        'strengths': strengths,
        'weaknesses': weaknesses,
        'nextGoal': nextGoal,
        'drills': [for (final d in drills) d.toJson()],
      };

  static List<String> _strings(Object? raw) => [
        if (raw is List)
          for (final s in raw)
            if (s.toString().trim().isNotEmpty) s.toString().trim(),
      ];
}

/// Extract the first JSON object from a model reply (tolerates ```json fences).
Map<String, dynamic>? decodeTrainerJson(String raw) {
  var s = raw.trim();
  // Strip a leading ```json ... ``` fence if the model wrapped the object.
  final fence = RegExp(
    r'^```(?:json|JSON)?\s*([\s\S]*?)\s*```\s*$',
  ).firstMatch(s);
  if (fence != null) s = fence.group(1)!.trim();
  final start = s.indexOf('{');
  final end = s.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = jsonDecode(s.substring(start, end + 1));
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  } catch (_) {
    return null;
  }
}

/// Soft cap for one pre-send grammar check (must match server).
const kTrainerMaxChars = 6000;

/// Only mostly-Latin messages with a few real words go to the coach.
bool shouldTrainerCheck(String text) {
  var t = text.trim();
  if (t.isEmpty || t.startsWith('#')) return false;
  t = t
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'`[^`]*`'), ' ')
      .replaceAll(RegExp(r'https?://\S+|www\.\S+'), ' ')
      .replaceAll(RegExp(r'[@:][\w.-]+:?'), ' ');
  final latin = RegExp(r'[A-Za-z]').allMatches(t).length;
  final letters = RegExp(r'\p{L}', unicode: true).allMatches(t).length;
  if (latin < 6 || letters == 0 || latin / letters < 0.7) return false;
  final words = RegExp(r"[A-Za-z][A-Za-z']+").allMatches(t).length;
  return words >= 2;
}

class TrainerSample {
  const TrainerSample({
    required this.text,
    required this.major,
    required this.minor,
    required this.at,
  });

  final String text;
  final int major;
  final int minor;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        't': text,
        'M': major,
        'm': minor,
        'at': at.toIso8601String(),
      };

  static TrainerSample? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['t']?.toString() ?? '';
    if (text.isEmpty) return null;
    return TrainerSample(
      text: text,
      major: (raw['M'] as num?)?.toInt() ?? 0,
      minor: (raw['m'] as num?)?.toInt() ?? 0,
      at: DateTime.tryParse(raw['at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

class TrainerMistake {
  const TrainerMistake({
    required this.wrong,
    required this.right,
    required this.type,
    required this.why,
    required this.at,
    this.example = '',
    this.major = true,
    this.original = '',
    this.corrected = '',
    this.natural = '',
  });

  final String wrong;
  final String right;
  final String type;
  final String why;
  final String example;
  final bool major;
  /// Full message the user typed (for revision later).
  final String original;
  final String corrected;
  final String natural;
  final DateTime at;

  TrainerIssue get asIssue => TrainerIssue(
        wrong: wrong,
        right: right,
        type: type,
        major: major,
        why: why,
        example: example,
      );

  /// Rebuild a [TrainerCheck] so the review dialog can reopen this lesson.
  TrainerCheck toCheck({List<TrainerIssue>? allIssues}) {
    final issues = allIssues ?? [asIssue];
    final orig = original.trim().isNotEmpty ? original : wrong;
    var fixed = corrected.trim();
    if (fixed.isEmpty) fixed = orig;
    return TrainerCheck(
      original: orig,
      corrected: fixed,
      issues: issues,
      natural: natural,
    );
  }

  Map<String, dynamic> toJson() => {
        'w': wrong,
        'r': right,
        'k': type,
        'y': why,
        'at': at.toIso8601String(),
        if (example.isNotEmpty) 'ex': example,
        'M': major ? 1 : 0,
        if (original.isNotEmpty) 'o': original,
        if (corrected.isNotEmpty) 'c': corrected,
        if (natural.isNotEmpty) 'n': natural,
      };

  static TrainerMistake? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final wrong = raw['w']?.toString() ?? '';
    final right = raw['r']?.toString() ?? '';
    if (wrong.isEmpty && right.isEmpty) return null;
    return TrainerMistake(
      wrong: wrong,
      right: right,
      type: raw['k']?.toString() ?? 'other',
      why: raw['y']?.toString() ?? '',
      example: raw['ex']?.toString() ?? '',
      major: raw['M'] != 0 && raw['M'] != false,
      original: raw['o']?.toString() ?? '',
      corrected: raw['c']?.toString() ?? '',
      natural: raw['n']?.toString() ?? '',
      at: DateTime.tryParse(raw['at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/// What the user did in the review popup.
enum TrainerOutcome { sentFixed, sentNatural, sentMine, edit }

/// Feedback for the toast after a check is recorded.
class TrainerReward {
  const TrainerReward({
    required this.xp,
    required this.streak,
    this.selfFix = false,
    this.milestone,
    this.rankUp,
  });

  final int xp;
  final int streak;
  final bool selfFix;

  /// Streak count just reached (5, 10, 25, …).
  final int? milestone;

  /// New rank title when XP crossed a threshold.
  final String? rankUp;
}

/// Fun XP ranks — separate from CEFR, rewards showing up and fixing things.
const List<({int xp, String title})> kTrainerRanks = [
  (xp: 0, title: 'Fresh Recruit'),
  (xp: 100, title: 'Comma Cadet'),
  (xp: 300, title: 'Tense Tamer'),
  (xp: 700, title: 'Article Ace'),
  (xp: 1500, title: 'Preposition Pro'),
  (xp: 3000, title: 'Syntax Samurai'),
  (xp: 6000, title: 'Grammar Overlord'),
];

const List<int> kTrainerStreakMilestones = [5, 10, 25, 50, 100, 250];

/// Device-local trainer progress.
class TrainerStats {
  TrainerStats();

  int checked = 0;
  int clean = 0;
  int majorErrors = 0;
  int minorErrors = 0;
  int streak = 0;
  int bestStreak = 0;
  int xp = 0;
  int selfFixes = 0;
  int sentFixed = 0;
  final Map<String, int> byType = {};
  final List<TrainerSample> samples = [];
  final List<TrainerMistake> mistakes = [];
  TrainerLevelReport? lastReport;

  /// Short history of past grades for the "you moved up" delta.
  final List<({CefrLevel level, int progress, DateTime at})> reportHistory = [];

  static const int maxSamples = 40;
  static const int maxMistakes = 30;
  static const int minSamplesForReview = 5;

  int get totalErrors => majorErrors + minorErrors;

  double get cleanRate => checked == 0 ? 0 : clean / checked;

  ({int xp, String title}) get rank {
    var r = kTrainerRanks.first;
    for (final step in kTrainerRanks) {
      if (xp >= step.xp) r = step;
    }
    return r;
  }

  ({int xp, String title})? get nextRank {
    for (final step in kTrainerRanks) {
      if (step.xp > xp) return step;
    }
    return null;
  }

  /// 0–1 progress from the current rank to the next.
  double get rankProgress {
    final next = nextRank;
    if (next == null) return 1;
    final from = rank.xp;
    return ((xp - from) / (next.xp - from)).clamp(0.0, 1.0);
  }

  List<MapEntry<String, int>> get topTypes {
    final list = byType.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// Record a check. [retry] = user edited after a review, so the message is
  /// not counted twice; a clean retry earns the self-fix bonus instead.
  TrainerReward recordCheck(TrainerCheck check, {bool retry = false}) {
    final rankBefore = rank.title;
    var gained = 0;
    int? milestone;
    var selfFix = false;
    if (!retry) {
      checked++;
      majorErrors += check.majorCount;
      minorErrors += check.minorCount;
      for (final i in check.issues) {
        byType[i.type] = (byType[i.type] ?? 0) + 1;
      }
      _pushMistakes(check);
      samples.add(
        TrainerSample(
          text: check.original.length > 400
              ? check.original.substring(0, 400)
              : check.original,
          major: check.majorCount,
          minor: check.minorCount,
          at: DateTime.now(),
        ),
      );
      while (samples.length > maxSamples) {
        samples.removeAt(0);
      }
    }
    if (!check.hasMajor) {
      if (retry) {
        selfFix = true;
        selfFixes++;
        gained += 8;
      } else {
        clean++;
        streak++;
        if (streak > bestStreak) bestStreak = streak;
        gained += 10 + min(streak, 10);
        if (kTrainerStreakMilestones.contains(streak)) {
          milestone = streak;
          gained += streak;
        }
      }
    } else if (!retry) {
      streak = 0;
    }
    xp += gained;
    final rankAfter = rank.title;
    return TrainerReward(
      xp: gained,
      streak: streak,
      selfFix: selfFix,
      milestone: milestone,
      rankUp: rankAfter != rankBefore ? rankAfter : null,
    );
  }

  int recordOutcome(TrainerOutcome outcome) {
    if (outcome != TrainerOutcome.sentFixed &&
        outcome != TrainerOutcome.sentNatural) {
      return 0;
    }
    sentFixed++;
    xp += 3;
    return 3;
  }

  void recordReport(TrainerLevelReport report) {
    lastReport = report;
    reportHistory.add(
      (level: report.level, progress: report.progress, at: report.at),
    );
    while (reportHistory.length > 12) {
      reportHistory.removeAt(0);
    }
    xp += 15;
  }

  /// The previous grade before [lastReport], if any.
  ({CefrLevel level, int progress, DateTime at})? get previousReport =>
      reportHistory.length >= 2 ? reportHistory[reportHistory.length - 2] : null;

  void _pushMistakes(TrainerCheck check) {
    final now = DateTime.now();
    final original = check.original.length > 800
        ? check.original.substring(0, 800)
        : check.original;
    final corrected = check.corrected.length > 800
        ? check.corrected.substring(0, 800)
        : check.corrected;
    final natural = check.natural.length > 400
        ? check.natural.substring(0, 400)
        : check.natural;
    for (final i in check.issues) {
      mistakes.add(
        TrainerMistake(
          wrong: i.wrong,
          right: i.right,
          type: i.type,
          why: i.why,
          example: i.example,
          major: i.major,
          original: original,
          corrected: corrected,
          natural: natural,
          at: now,
        ),
      );
    }
    while (mistakes.length > maxMistakes) {
      mistakes.removeAt(0);
    }
  }

  /// Other slips recorded from the same message (same original + timestamp).
  List<TrainerMistake> siblingsOf(TrainerMistake m) {
    if (m.original.trim().isEmpty) return [m];
    final ms = m.at.millisecondsSinceEpoch;
    final list = mistakes
        .where(
          (o) =>
              o.original == m.original &&
              (o.at.millisecondsSinceEpoch - ms).abs() < 2000,
        )
        .toList();
    return list.isEmpty ? [m] : list;
  }

  /// JSON payload for the level-review prompt.
  String levelReviewPayload() {
    final recent = samples.length > 30
        ? samples.sublist(samples.length - 30)
        : samples;
    return jsonEncode({
      'messagesChecked': checked,
      'cleanMessages': clean,
      'majorMistakes': majorErrors,
      'minorMistakes': minorErrors,
      'mistakesByType': byType,
      if (lastReport != null)
        'previousGrade': '${lastReport!.level.code} ${lastReport!.progress}%',
      'samples': [
        for (final s in recent)
          {'text': s.text, 'major': s.major, 'minor': s.minor},
      ],
    });
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'checked': checked,
        'clean': clean,
        'major': majorErrors,
        'minor': minorErrors,
        'streak': streak,
        'best': bestStreak,
        'xp': xp,
        'selfFixes': selfFixes,
        'sentFixed': sentFixed,
        'byType': byType,
        'samples': [for (final s in samples) s.toJson()],
        'mistakes': [for (final m in mistakes) m.toJson()],
        if (lastReport != null) 'report': lastReport!.toJson(),
        'history': [
          for (final h in reportHistory)
            {'l': h.level.name, 'p': h.progress, 'at': h.at.toIso8601String()},
        ],
      };

  String encode() => jsonEncode(toJson());

  static TrainerStats decode(String? raw) {
    final stats = TrainerStats();
    if (raw == null || raw.isEmpty) return stats;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return stats;
      int n(String k) => (map[k] as num?)?.toInt() ?? 0;
      stats
        ..checked = n('checked')
        ..clean = n('clean')
        ..majorErrors = n('major')
        ..minorErrors = n('minor')
        ..streak = n('streak')
        ..bestStreak = n('best')
        ..xp = n('xp')
        ..selfFixes = n('selfFixes')
        ..sentFixed = n('sentFixed');
      final types = map['byType'];
      if (types is Map) {
        for (final e in types.entries) {
          final v = (e.value as num?)?.toInt() ?? 0;
          if (v > 0) stats.byType[e.key.toString()] = v;
        }
      }
      for (final s in (map['samples'] as List?) ?? const []) {
        final sample = TrainerSample.fromJson(s);
        if (sample != null) stats.samples.add(sample);
      }
      for (final m in (map['mistakes'] as List?) ?? const []) {
        final mistake = TrainerMistake.fromJson(m);
        if (mistake != null) stats.mistakes.add(mistake);
      }
      final report = map['report'];
      if (report is Map) {
        stats.lastReport = TrainerLevelReport.fromJson(report);
      }
      for (final h in (map['history'] as List?) ?? const []) {
        if (h is! Map) continue;
        final level = CefrLevelX.parse(h['l']);
        if (level == null) continue;
        stats.reportHistory.add((
          level: level,
          progress: (h['p'] as num?)?.toInt() ?? 0,
          at: DateTime.tryParse(h['at']?.toString() ?? '') ?? DateTime.now(),
        ));
      }
    } catch (_) {
      return TrainerStats();
    }
    return stats;
  }
}

final _trainerRng = Random();

String _pick(List<String> pool) => pool[_trainerRng.nextInt(pool.length)];

/// Toast line for a clean send.
String trainerCleanLine() => _pick(const [
      'Clean as a whistle.',
      'No notes. Chef’s kiss.',
      'Shakespeare nods approvingly.',
      'Grammar police: nothing to see here.',
      'Smooth. Suspiciously smooth.',
      'Your English teacher just felt a disturbance of joy.',
      'Flawless. The coach is bored — in a good way.',
      'Textbook. Literally.',
      'That sentence could go on a poster.',
      'Zero mistakes. Show-off.',
    ]);

String trainerSelfFixLine() => _pick(const [
      'Fixed it yourself — that’s how it sticks.',
      'You found it. The coach is proud.',
      'Self-correction unlocked. Brain gains.',
      'Nailed the fix. That one won’t come back.',
    ]);

String trainerMilestoneLine(int streak) => switch (streak) {
      5 => '5 clean in a row — warming up!',
      10 => '10-streak! The coach is taking notes.',
      25 => '25 clean messages. Are you secretly British?',
      50 => '50-streak. Grammar has chosen you.',
      100 => '100-streak. Legends are written in Present Perfect.',
      _ => '$streak-streak. Unstoppable.',
    };

/// Fallback quip when the model skips one.
String trainerFallbackQuip(int major) => major <= 1
    ? _pick(const [
        'So close! One tiny gremlin sneaked in.',
        'Almost perfect — let’s squash this bug.',
        'One slip. Even natives do this (they just don’t admit it).',
      ])
    : _pick(const [
        'A few gremlins in there. Let’s evict them.',
        'Grammar gym time — nothing heavy, promise.',
        'Your ideas are great; the grammar wants a word.',
      ]);
