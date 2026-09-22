import 'dart:math';

/// Manner for the greeting draft above the composer.
enum GreetingStyle {
  /// "Hi, Name," plus a random offline category (joke / philosophy / …).
  sayHi,

  /// @nodoc keep old name as alias for regenerate compatibility in older state.
  random,

  joke,
  philosophy,
  work,
  warm,
  punchy,

  /// Offline English grammar rule + example sentence.
  english,

  /// Context-aware draft from AI (chat history).
  ai,
}

/// Fixed pool — English names for UI and local quote banks.
const List<String> kGreetingPhilosophers = [
  'Seneca',
  'Cicero',
  'Voltaire',
  'Baruch Spinoza',
  'Kant',
  'Hegel',
  'Schopenhauer',
  'Nietzsche',
  'Martin Heidegger',
  'Karl Marx',
  'Otto Weininger',
];

/// Joke category ids (match keys in greeting_pools.json).
const List<String> kGreetingJokeCategories = [
  'clean',
  'office',
  'technology',
  'science',
  'dad',
];

/// English mode ids (match keys in greeting_pools.json → english).
const List<String> kGreetingEnglishCategories = [
  'geoffrey',
];

String greetingEnglishCategoryLabel(String id) => switch (id) {
      'geoffrey' => 'Grammar',
      _ => id.isEmpty
          ? id
          : '${id[0].toUpperCase()}${id.substring(1)}',
    };

String greetingJokeCategoryLabel(String id) => switch (id) {
      'clean' => 'Clean',
      'office' => 'Office',
      'technology' => 'Technology',
      'science' => 'Science',
      'dad' => 'Dad',
      'sports' => 'Sports',
      'family' => 'Family',
      'school' => 'School',
      'miscellaneous' => 'Misc',
      'wordplay' => 'Wordplay',
      'animal' => 'Animal',
      'food' => 'Food',
      'programming' => 'Programming',
      'general' => 'General',
      'knock-knock' => 'Knock-knock',
      _ => id.isEmpty
          ? id
          : '${id[0].toUpperCase()}${id.substring(1)}',
    };

final _greetingRng = Random();

extension GreetingStyleX on GreetingStyle {
  String get id => name;

  String get label => switch (this) {
        GreetingStyle.sayHi || GreetingStyle.random => 'Say hi',
        GreetingStyle.joke => 'Joke',
        GreetingStyle.philosophy => 'Philosophy',
        GreetingStyle.work => 'Work',
        GreetingStyle.warm => 'Warm',
        GreetingStyle.punchy => 'Punchy',
        GreetingStyle.english => 'English',
        GreetingStyle.ai => 'AI',
      };

  String get tooltip => switch (this) {
        GreetingStyle.sayHi || GreetingStyle.random =>
          '“Hi, Name,” plus a random joke / quote / line',
        GreetingStyle.joke => 'Joke only — no Hi (pick type or Random)',
        GreetingStyle.philosophy =>
          'Quote only — no Hi (pick a thinker or Random)',
        GreetingStyle.work => 'Work/craft quote only — no Hi (offline)',
        GreetingStyle.warm => 'Warm line only — no Hi (offline)',
        GreetingStyle.punchy => 'Short punchy line only — no Hi (offline)',
        GreetingStyle.english =>
          'Grammar drill only — no Hi (offline rules + examples)',
        GreetingStyle.ai =>
          'AI writes something encouraging & fun from recent chat',
      };

  /// Offline styles shown in the main chip row (excludes AI and plain sayHi).
  static const List<GreetingStyle> offlineExtras = [
    GreetingStyle.joke,
    GreetingStyle.philosophy,
    GreetingStyle.work,
    GreetingStyle.warm,
    GreetingStyle.punchy,
    GreetingStyle.english,
  ];

  /// Concrete offline manners used when picking a random extra style.
  static const List<GreetingStyle> concrete = offlineExtras;

  bool get isLocal => this != GreetingStyle.ai;

  bool get needsAi => this == GreetingStyle.ai;

  /// Resolve legacy random → plain say-hi.
  GreetingStyle resolve() {
    if (this == GreetingStyle.random) return GreetingStyle.sayHi;
    return this;
  }

  /// Pick a philosopher from [kGreetingPhilosophers].
  static String pickPhilosopher() {
    final list = kGreetingPhilosophers;
    return list[_greetingRng.nextInt(list.length)];
  }

  /// Pick a joke category id from [kGreetingJokeCategories].
  static String pickJokeCategory() {
    final list = kGreetingJokeCategories;
    return list[_greetingRng.nextInt(list.length)];
  }

  /// Pick an English mode id from [kGreetingEnglishCategories].
  static String pickEnglishCategory() {
    final list = kGreetingEnglishCategories;
    return list[_greetingRng.nextInt(list.length)];
  }

  bool get allowsLonger =>
      this == GreetingStyle.philosophy ||
      this == GreetingStyle.work ||
      this == GreetingStyle.english;
}
