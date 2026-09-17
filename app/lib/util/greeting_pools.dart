import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import 'greeting_style.dart';

/// Offline greeting pools baked into the app (Wikiquote / curated fillers).
class GreetingPools {
  static GreetingPools? _instance;
  static final _rng = Random();

  final Map<String, List<String>> philosophy;
  final List<({String text, String author})> work;
  /// Joke lines keyed by category id (`programming`, `general`, …).
  final Map<String, List<String>> jokes;
  final List<String> warm;
  final List<String> punchy;
  /// English lines keyed by mode id (`geoffrey`, `lesson`).
  final Map<String, List<String>> english;

  GreetingPools({
    required this.philosophy,
    required this.work,
    required this.jokes,
    required this.warm,
    required this.punchy,
    required this.english,
  });

  /// Categories that actually have at least one joke (UI order).
  List<String> get jokeCategories {
    final out = <String>[];
    for (final id in kGreetingJokeCategories) {
      final pool = jokes[id];
      if (pool != null && pool.isNotEmpty) out.add(id);
    }
    for (final e in jokes.entries) {
      if (e.value.isEmpty) continue;
      if (!out.contains(e.key)) out.add(e.key);
    }
    return out;
  }

  /// English modes that have content (UI order).
  List<String> get englishCategories {
    final out = <String>[];
    for (final id in kGreetingEnglishCategories) {
      final pool = english[id];
      if (pool != null && pool.isNotEmpty) out.add(id);
    }
    for (final e in english.entries) {
      if (e.value.isEmpty) continue;
      if (!out.contains(e.key)) out.add(e.key);
    }
    return out;
  }

  static Future<GreetingPools> load() async {
    final cached = _instance;
    if (cached != null) return cached;
    final raw =
        await rootBundle.loadString('assets/greetings/greeting_pools.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final phil = <String, List<String>>{};
    final philRaw = json['philosophy'] as Map<String, dynamic>? ?? {};
    for (final e in philRaw.entries) {
      phil[e.key] = (e.value as List)
          .map((x) => x.toString().trim())
          .where((x) => x.isNotEmpty)
          .toList(growable: false);
    }
    final work = <({String text, String author})>[];
    for (final item in (json['work'] as List? ?? const [])) {
      if (item is! Map) continue;
      final text = (item['text'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      work.add((
        text: text,
        author: (item['author'] ?? 'Unknown').toString().trim(),
      ));
    }
    List<String> strList(String key) => ((json[key] as List?) ?? const [])
        .map((x) => x.toString().trim())
        .where((x) => x.isNotEmpty)
        .toList(growable: false);

    final jokes = <String, List<String>>{};
    final jokesRaw = json['jokes'];
    if (jokesRaw is Map) {
      for (final e in jokesRaw.entries) {
        final id = e.key.toString().trim().toLowerCase();
        if (id.isEmpty) continue;
        jokes[id] = (e.value as List? ?? const [])
            .map((x) => x.toString().trim())
            .where((x) => x.isNotEmpty)
            .toList(growable: false);
      }
    } else if (jokesRaw is List) {
      // Legacy flat list → general.
      jokes['general'] = jokesRaw
          .map((x) => x.toString().trim())
          .where((x) => x.isNotEmpty)
          .toList(growable: false);
    }

    final english = <String, List<String>>{};
    final englishRaw = json['english'];
    if (englishRaw is Map) {
      for (final e in englishRaw.entries) {
        final id = e.key.toString().trim().toLowerCase();
        if (id.isEmpty) continue;
        english[id] = (e.value as List? ?? const [])
            .map((x) => x.toString().trim())
            .where((x) => x.isNotEmpty)
            .toList(growable: false);
      }
    } else if (englishRaw is List) {
      // Legacy flat list → Geoffrey drills.
      english['geoffrey'] = englishRaw
          .map((x) => x.toString().trim())
          .where((x) => x.isNotEmpty)
          .toList(growable: false);
    }

    final pools = GreetingPools(
      philosophy: phil,
      work: List.unmodifiable(work),
      jokes: Map.unmodifiable(jokes),
      warm: strList('warm'),
      punchy: strList('punchy'),
      english: Map.unmodifiable(english),
    );
    _instance = pools;
    return pools;
  }

  /// Drop cached pools (tests / hot reload after asset swap).
  static void resetCache() => _instance = null;

  static T _pick<T>(List<T> list) {
    if (list.isEmpty) {
      throw StateError('empty greeting pool');
    }
    return list[_rng.nextInt(list.length)];
  }

  /// Prefer a line not in [avoid] (case-insensitive substring / equality).
  static String _pickFresh(List<String> list, Set<String> avoid) {
    if (list.isEmpty) return '';
    if (avoid.isEmpty) return _pick(list);
    final fresh = <String>[];
    for (final q in list) {
      final low = q.toLowerCase();
      var hit = false;
      for (final a in avoid) {
        if (a.isEmpty) continue;
        if (low == a || low.contains(a) || a.contains(low)) {
          hit = true;
          break;
        }
      }
      if (!hit) fresh.add(q);
    }
    return _pick(fresh.isNotEmpty ? fresh : list);
  }

  List<String> _jokePoolFor(String? category) {
    final id = (category ?? '').trim().toLowerCase();
    if (id.isNotEmpty) {
      final pool = jokes[id];
      if (pool != null && pool.isNotEmpty) return pool;
    }
    // Random category with content, weighted by size.
    final nonempty = jokes.entries.where((e) => e.value.isNotEmpty).toList();
    if (nonempty.isEmpty) return const [];
    final flat = <String>[];
    for (final e in nonempty) {
      flat.addAll(e.value);
    }
    return flat;
  }

  List<String> _englishPoolFor(String? category) {
    final id = (category ?? '').trim().toLowerCase();
    if (id.isNotEmpty) {
      final pool = english[id];
      if (pool != null && pool.isNotEmpty) return pool;
    }
    final nonempty = english.entries.where((e) => e.value.isNotEmpty).toList();
    if (nonempty.isEmpty) return const [];
    final flat = <String>[];
    for (final e in nonempty) {
      flat.addAll(e.value);
    }
    return flat;
  }

  String compose({
    required GreetingStyle style,
    String? firstName,
    String? philosopher,
    String? jokeCategory,
    String? englishCategory,
    List<String> avoid = const [],
  }) {
    final hi = (firstName != null && firstName.isNotEmpty)
        ? 'Hi, $firstName,'
        : 'Hi there,';
    final avoidSet = {
      for (final a in avoid) a.toLowerCase().trim(),
    }..removeWhere((s) => s.isEmpty);

    final resolved =
        style == GreetingStyle.random ? GreetingStyle.sayHi : style;

    switch (resolved) {
      case GreetingStyle.sayHi:
      case GreetingStyle.random:
        return hi.endsWith(',') ? '${hi.substring(0, hi.length - 1)}.' : '$hi.';
      case GreetingStyle.joke:
        final pool = _jokePoolFor(jokeCategory);
        if (pool.isEmpty) return hi;
        final joke = _pickFresh(pool, avoidSet);
        return '$hi $joke';
      case GreetingStyle.warm:
        final line = _pickFresh(warm, avoidSet);
        return '$hi $line';
      case GreetingStyle.punchy:
        final line = _pickFresh(punchy, avoidSet);
        return '$hi $line';
      case GreetingStyle.english:
        final pool = _englishPoolFor(englishCategory);
        if (pool.isEmpty) return hi;
        final line = _pickFresh(pool, avoidSet);
        return '$hi\n[English lesson]\n$line';
      case GreetingStyle.work:
        if (work.isEmpty) return hi;
        final pick = _pick(work);
        // Prefer unused text when possible.
        final candidates = work.where((w) {
          final low = w.text.toLowerCase();
          for (final a in avoidSet) {
            if (a.isEmpty) continue;
            if (low == a || low.contains(a) || a.contains(low)) return false;
          }
          return true;
        }).toList();
        final w = candidates.isNotEmpty ? _pick(candidates) : pick;
        final who = w.author.isNotEmpty && w.author != 'Unknown'
            ? w.author
            : null;
        return who == null
            ? '$hi\n\n"${w.text}"'
            : '$hi\n\n"${w.text}"\n— $who';
      case GreetingStyle.philosophy:
        final name = (philosopher != null && philosopher.trim().isNotEmpty)
            ? philosopher.trim()
            : GreetingStyleX.pickPhilosopher();
        final pool = philosophy[name] ?? const <String>[];
        if (pool.isEmpty) {
          // Fallback: any philosopher with quotes.
          final nonempty = philosophy.entries
              .where((e) => e.value.isNotEmpty)
              .toList();
          if (nonempty.isEmpty) return hi;
          final entry = _pick(nonempty);
          final q = _pickFresh(entry.value, avoidSet);
          return '$hi\n\n"$q"\n— ${entry.key}';
        }
        final q = _pickFresh(pool, avoidSet);
        return '$hi\n\n"$q"\n— $name';
      case GreetingStyle.ai:
        // AI path is handled by the network caller.
        return hi;
    }
  }
}
