import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/english_trainer.dart';

void main() {
  group('TrainerCheck.parse', () {
    test('reads fenced JSON with issues', () {
      const raw = '''```json
{"corrected":"I went to the shop yesterday.","issues":[
 {"wrong":"goed","right":"went","type":"Tense","severity":"major","why":"Go is irregular.","example":"We went home."},
 {"wrong":"to shop","right":"to the shop","type":"article","severity":"minor","why":"Specific place.","example":"At the bank."}
],"natural":"Popped to the shop yesterday.","quip":"Goed? Gone!","cefr":"B1"}
```''';
      final c = TrainerCheck.parse('I goed to shop yesterday.', raw)!;
      expect(c.issues, hasLength(2));
      expect(c.issues.first.type, 'tense');
      expect(c.majorCount, 1);
      expect(c.minorCount, 1);
      expect(c.hasMajor, isTrue);
      expect(c.cefr, CefrLevel.b1);
      expect(c.natural, isNotEmpty);
    });

    test('coach version is surgical fixes; model rewrite becomes natural', () {
      const original =
          'So, this English coach work as should? Can I use you in my regular conversations, bro?';
      const raw = '''
{"corrected":"So, does this English coach work like it's supposed to? Can I use you in my everyday conversations, bro?",
 "issues":[
  {"wrong":"work","right":"works","type":"agreement","severity":"major","why":"Singular subject needs works.","example":"This app works well."},
  {"wrong":"as should","right":"as it should","type":"missing_word","severity":"major","why":"Need the subject it after as.","example":"It works as it should."}
 ],
 "natural":"",
 "quip":"Almost there, coach.","cefr":"B1"}
''';
      final c = TrainerCheck.parse(original, raw)!;
      expect(
        c.corrected,
        'So, this English coach works as it should? Can I use you in my regular conversations, bro?',
      );
      expect(c.natural, contains("supposed to"));
      expect(c.issues, hasLength(2));
    });

    test('no issues keeps original and drops identical natural', () {
      final c = TrainerCheck.parse(
        'See you tomorrow',
        '{"corrected":"See you tomorrow.","issues":[],"natural":"See you tomorrow!","quip":"","cefr":"A2"}',
      )!;
      expect(c.issues, isEmpty);
      expect(c.corrected, 'See you tomorrow');
      expect(c.natural, isEmpty);
    });

    test('rejects prose', () {
      expect(TrainerCheck.parse('hi there', 'Looks good to me!'), isNull);
    });

    test('repairs truncated JSON so a long message is still readable', () {
      const original =
          'Have you updated Privet? If no, can you update and se how it is '
          'correcting me.\n\nlong text like this almost always coac can\'t read.';
      const raw = '''```json
{"issues":[
 {"wrong":"If no","right":"If not","type":"word_choice","severity":"minor","why":"Use if not.","example":"If not, call me."},
 {"wrong":"se how","right":"see how","type":"spelling","severity":"minor","why":"See is the verb.","example":"See how it works."},
 {"wrong":"coac","right":"coach","type":"spelling","severity":"major","why":"Spelling.","example":"The coach can read it."}
],"quip":"Coach can read this.","cefr":"B1","natural":"If not, update and see how it''';
      final c = TrainerCheck.parse(original, raw)!;
      expect(c.issues, hasLength(3));
      expect(c.corrected, contains('If not'));
      expect(c.corrected, contains('see how'));
      expect(c.corrected, contains('coach'));
      expect(c.corrected, contains('\n\n'));
    });

    test('applies the issues it can find when one span is missing', () {
      final c = TrainerCheck.parse(
        'He go home yesterday',
        '{"issues":[{"wrong":"go","right":"goes","type":"agreement","severity":"major","why":"He takes goes.","example":"He goes home."},{"wrong":"NOT_IN_TEXT","right":"x","type":"other","severity":"minor","why":"","example":""}]}',
      )!;
      expect(c.corrected, 'He goes home yesterday');
      expect(c.issues, hasLength(2));
    });

    test('accepts a bare issues array', () {
      final c = TrainerCheck.parse(
        'I goed',
        '[{"wrong":"goed","right":"went","type":"tense","severity":"major","why":"Irregular.","example":"I went."}]',
      )!;
      expect(c.corrected, 'I went');
    });

    test('skips no-op issues and unknown types become other', () {
      final c = TrainerCheck.parse(
        'a b',
        '{"corrected":"a b","issues":[{"wrong":"a","right":"a"},{"wrong":"b","right":"c","type":"weird"}]}',
      )!;
      expect(c.issues, hasLength(1));
      expect(c.issues.single.type, 'other');
      expect(c.issues.single.major, isTrue);
    });
  });

  test('trainerIssueSpans finds non-overlapping case-insensitive spans', () {
    const text = 'He go to school and he go home';
    final issues = [
      const TrainerIssue(
        wrong: 'go',
        right: 'goes',
        type: 'agreement',
        major: true,
        why: '',
        example: '',
      ),
      const TrainerIssue(
        wrong: 'go',
        right: 'goes',
        type: 'agreement',
        major: true,
        why: '',
        example: '',
      ),
    ];
    final spans = trainerIssueSpans(text, issues);
    expect(spans, hasLength(2));
    expect(spans[0].start, 3);
    expect(spans[1].start, text.lastIndexOf('go'));
  });

  test('trainerIssueSpans prefers whole words ("i" not inside "big")', () {
    const text = 'a big day, i think';
    final spans = trainerIssueSpans(text, const [
      TrainerIssue(
        wrong: 'i',
        right: 'I',
        type: 'capitalization',
        major: false,
        why: '',
        example: '',
      ),
    ]);
    expect(spans.single.start, text.indexOf(', i ') + 2);
  });

  group('shouldTrainerCheck', () {
    test('English sentence', () {
      expect(shouldTrainerCheck('I think we should go tomorrow'), isTrue);
    });
    test('Russian, AI commands, one word, links', () {
      expect(shouldTrainerCheck('Привет, как дела у тебя?'), isFalse);
      expect(shouldTrainerCheck('# summarize'), isFalse);
      expect(shouldTrainerCheck('okay'), isFalse);
      expect(shouldTrainerCheck('https://example.com/page'), isFalse);
    });
  });

  group('TrainerStats', () {
    TrainerCheck clean() =>
        const TrainerCheck(original: 'All good here', corrected: 'All good here', issues: []);
    TrainerCheck bad() => const TrainerCheck(
          original: 'He go home',
          corrected: 'He goes home',
          natural: 'He\'s heading home',
          issues: [
            TrainerIssue(
              wrong: 'go',
              right: 'goes',
              type: 'agreement',
              major: true,
              why: 'He/she/it takes goes in the present.',
              example: 'She goes to school.',
            ),
          ],
        );

    test('streak, xp, milestone and reset on a mistake', () {
      final s = TrainerStats();
      TrainerReward? last;
      for (var i = 0; i < 5; i++) {
        last = s.recordCheck(clean());
      }
      expect(s.streak, 5);
      expect(last!.milestone, 5);
      expect(s.checked, 5);
      final xpBefore = s.xp;
      s.recordCheck(bad());
      expect(s.streak, 0);
      expect(s.bestStreak, 5);
      expect(s.xp, xpBefore);
      expect(s.byType['agreement'], 1);
      expect(s.mistakes, hasLength(1));
    });

    test('clean retry is a self-fix and is not counted twice', () {
      final s = TrainerStats();
      s.recordCheck(bad());
      final r = s.recordCheck(clean(), retry: true);
      expect(r.selfFix, isTrue);
      expect(s.checked, 1);
      expect(s.selfFixes, 1);
      expect(s.xp, 8);
    });

    test('round-trips through encode/decode', () {
      final s = TrainerStats()
        ..recordCheck(clean())
        ..recordCheck(bad());
      s.recordReport(
        TrainerLevelReport.parse(
          '{"level":"B2","progress":40,"title":"Tense Tamer","drills":[{"prompt":"I ___ here","answer":"have lived"}]}',
        )!,
      );
      final back = TrainerStats.decode(s.encode());
      expect(back.checked, 2);
      expect(back.majorErrors, 1);
      expect(back.samples, hasLength(2));
      expect(back.lastReport!.level, CefrLevel.b2);
      expect(back.lastReport!.drills.single.answer, 'have lived');
      expect(back.reportHistory, hasLength(1));
      expect(back.mistakes, hasLength(1));
      expect(back.mistakes.single.original, 'He go home');
      expect(back.mistakes.single.why, contains('goes'));
      expect(back.mistakes.single.example, 'She goes to school.');
      expect(back.mistakes.single.natural, "He's heading home");
      final lesson = back.mistakes.single.toCheck();
      expect(lesson.issues.single.right, 'goes');
      expect(lesson.corrected, 'He goes home');
    });

    test('decode tolerates garbage', () {
      expect(TrainerStats.decode('not json').checked, 0);
    });
  });

  test('level report ladder position', () {
    final r = TrainerLevelReport.parse('{"level":"c2","progress":100}')!;
    expect(r.ladderPosition, 1);
    expect(TrainerLevelReport.parse('{"level":"Z9"}'), isNull);
  });
}
