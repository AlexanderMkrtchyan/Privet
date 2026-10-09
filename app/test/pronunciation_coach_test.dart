import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/pronunciation_hint.dart';
import 'package:privet/util/pronunciation_result.dart';

void main() {
  test('a dental slip blocks a match; an unsure vowel does not', () {
    final result = PronunciationAssessment.parse('''
{
  "passed": false,
  "slips": 1,
  "words": [
    {
      "position": 0,
      "word": "think",
      "expected": "θɪŋk",
      "heard": "sɪŋk",
      "ok": false,
      "phones": [
        {"expected": "θ", "heard": "s", "confidence": 0.49, "counts": true, "at": "start"}
      ]
    },
    {
      "position": 2,
      "word": "about",
      "expected": "əbaʊt",
      "heard": "əbaʊt",
      "ok": true,
      "phones": []
    }
  ],
  "reference_wav_b64": ""
}
''');
    expect(result.passed, isFalse);
    expect(result.slips, 1);
    expect(result.words.first.phones.single.expected, 'θ');
    expect(result.words.first.phones.single.heard, 's');
    expect(result.words.first.ok, isFalse);
    expect(result.words.last.ok, isTrue);
    expect(result.wordAtPosition(0)?.word, 'think');
    expect(result.wordAtPosition(1), isNull);
    expect(result.wordAtPosition(2)?.word, 'about');
    expect(result.referenceWav, isEmpty);
    expect(
      describeSlip(result.words.first.word, result.words.first.phones.single),
      'think — в начале «th» прозвучало как «s»',
    );
    expect(
      describeSlip(
        'thing',
        const PhoneSlip(
          expected: 'θ',
          heard: '',
          confidence: 1,
          counts: true,
          at: 'start',
        ),
      ),
      'thing — в начале не слышно «th»',
    );
  });

  test('a hint explains the reference, the heard sound, and the fix', () {
    const word = WordPronunciation(
      position: 0,
      word: 'infinite',
      expected: 'ˈɪnfɪnət',
      heard: 'ɪnfɪnɪt',
      ok: false,
      phones: [
        PhoneSlip(
          expected: 'ə',
          heard: 'ɪ',
          confidence: 0.8,
          counts: true,
          at: 'end',
        ),
      ],
    );
    final hint = pronunciationHint(word);
    expect(hint.correctReading, 'и\u0301нфинэт');
    expect(hint.correct, contains('Ударение на первом слоге'));
    expect(hint.correct, contains('шва'));
    expect(hint.heard, contains('краткий «и»'));
    expect(hint.fix, contains('между «а» и «э»'));

    final dental = pronunciationHint(
      const WordPronunciation(
        position: 0,
        word: 'think',
        expected: 'θɪŋk',
        heard: 'sɪŋk',
        ok: false,
        phones: [
          PhoneSlip(
            expected: 'θ',
            heard: 's',
            confidence: 0.49,
            counts: true,
            at: 'start',
          ),
        ],
      ),
    );
    expect(dental.fix, contains('между зубами'));
  });
}
