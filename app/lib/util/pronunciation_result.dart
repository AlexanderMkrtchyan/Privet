import 'dart:convert';
import 'dart:typed_data';

/// One sound the recognizer heard differently from the reference.
class PhoneSlip {
  const PhoneSlip({
    required this.expected,
    required this.heard,
    required this.confidence,
    required this.counts,
    required this.at,
  });

  final String expected;
  final String heard;
  final double confidence;

  /// Where in the word: start, middle, end, or only.
  final String at;

  /// Counts against a perfect reading. Close vowels the model is unsure
  /// about stay visible but do not block a match.
  final bool counts;

  factory PhoneSlip.fromJson(Map<String, dynamic> json) {
    return PhoneSlip(
      expected: json['expected'] as String? ?? '',
      heard: json['heard'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      counts: json['counts'] == true,
      at: json['at'] as String? ?? '',
    );
  }
}

/// One word of the sentence, with the sounds that did not match.
class WordPronunciation {
  const WordPronunciation({
    required this.position,
    required this.word,
    required this.expected,
    required this.heard,
    required this.ok,
    required this.phones,
  });

  /// Zero-based token position in the source text.
  final int position;
  final String word;
  final String expected;
  final String heard;
  final bool ok;
  final List<PhoneSlip> phones;

  factory WordPronunciation.fromJson(Map<String, dynamic> json) {
    final raw = json['phones'];
    final phones = raw is List
        ? raw
              .whereType<Map>()
              .map((e) => PhoneSlip.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const <PhoneSlip>[];
    return WordPronunciation(
      position: (json['position'] as num?)?.toInt() ?? -1,
      word: json['word'] as String? ?? '',
      expected: json['expected'] as String? ?? '',
      heard: json['heard'] as String? ?? '',
      ok: json['ok'] == true,
      phones: phones,
    );
  }
}

/// Result of one read-aloud check, plus the reference reading as wav bytes.
class PronunciationAssessment {
  const PronunciationAssessment({
    required this.passed,
    required this.slips,
    required this.words,
    required this.referenceWav,
  });

  /// No sound left that counts against the reference.
  final bool passed;
  final int slips;
  final List<WordPronunciation> words;
  final Uint8List referenceWav;

  static const maxChars = 300;

  /// Finds the backend result for a source-text token. Older local servers did
  /// not return positions, so keep ordinal fallback for compatibility.
  WordPronunciation? wordAtPosition(int position) {
    for (final word in words) {
      if (word.position == position) return word;
    }
    final hasPositions = words.any((word) => word.position >= 0);
    if (!hasPositions && position >= 0 && position < words.length) {
      return words[position];
    }
    return null;
  }

  factory PronunciationAssessment.parse(String body) {
    final json = jsonDecode(body);
    if (json is! Map) {
      throw const FormatException('pronunciation response was not an object');
    }
    final map = Map<String, dynamic>.from(json);
    final rawWords = map['words'];
    final words = rawWords is List
        ? rawWords
              .whereType<Map>()
              .map(
                (e) => WordPronunciation.fromJson(Map<String, dynamic>.from(e)),
              )
              .toList()
        : const <WordPronunciation>[];
    final b64 = map['reference_wav_b64'] as String? ?? '';
    return PronunciationAssessment(
      passed: map['passed'] == true,
      slips: (map['slips'] as num?)?.toInt() ?? 0,
      words: words,
      referenceWav: b64.isEmpty ? Uint8List(0) : base64Decode(b64),
    );
  }
}

const _soundSpellings = <String, String>{
  'θ': 'th',
  'ð': 'th',
  'ʃ': 'sh',
  'ʒ': 'zh',
  'tʃ': 'ch',
  'dʒ': 'j',
  'ŋ': 'ng',
  'ɹ': 'r',
  'r': 'r',
  'j': 'y',
  'ɡ': 'g',
  'g': 'g',
  'eɪ': 'ay',
  'aɪ': 'eye',
  'ɔɪ': 'oy',
  'aʊ': 'ow',
  'oʊ': 'oh',
  'ɪ': 'i',
  'i': 'ee',
  'ʊ': 'oo',
  'u': 'oo',
  'æ': 'a',
  'ɛ': 'e',
  'e': 'e',
  'ɑ': 'ah',
  'a': 'ah',
  'ʌ': 'uh',
  'ə': 'uh',
  'ɚ': 'er',
  'ɜ': 'er',
  'ɔ': 'aw',
  'o': 'o',
};

/// How a learner writes the sound: th, sh, ng — not IPA.
String soundSpelling(String ipa) {
  if (ipa.isEmpty) return '';
  return _soundSpellings[ipa] ?? ipa;
}

/// One plain sentence about a missed sound.
String describeSlip(String word, PhoneSlip phone) {
  final sound = soundSpelling(phone.expected);
  final heard = soundSpelling(phone.heard);
  final where = switch (phone.at) {
    'start' => 'в начале',
    'end' => 'в конце',
    _ => '',
  };
  if (phone.heard.isEmpty) {
    if (where.isEmpty) return '$word — не слышно «$sound»';
    return '$word — $where не слышно «$sound»';
  }
  if (where.isEmpty) return '$word — «$sound» прозвучало как «$heard»';
  return '$word — $where «$sound» прозвучало как «$heard»';
}
