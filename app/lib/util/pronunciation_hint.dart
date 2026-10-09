import 'pronunciation_result.dart';

/// Plain-language reading of one mismatched word.
class PronunciationHint {
  const PronunciationHint({
    required this.correctReading,
    required this.heardReading,
    required this.correct,
    required this.heard,
    required this.fix,
  });

  /// Rough Russian spelling of the reference, with stress.
  final String correctReading;

  /// Rough Russian spelling of what the recognizer heard.
  final String heardReading;

  final String correct;
  final String heard;
  final String fix;
}

/// Explains a scored word the way a teacher would: reference, what was
/// heard, and the mouth shape to change.
PronunciationHint pronunciationHint(WordPronunciation word) {
  final slips = word.phones.where((phone) => phone.counts).toList();
  final shown = slips.isEmpty ? word.phones : slips;
  final correctReading = roughReading(word.expected);
  final heardReading = word.heard.isEmpty ? '' : roughReading(word.heard);
  final stress = _stressSentence(word.expected);

  final correctDetails = shown
      .map(
        (phone) =>
            '${_place(phone.at)} нужен ${_describeSound(phone.expected)}.',
      )
      .join(' ');
  final heardDetails = shown
      .map((phone) {
        final place = _place(phone.at);
        if (phone.heard.isEmpty) {
          return '$place этот звук пропал.';
        }
        return '$place вместо этого прозвучал ${_describeSound(phone.heard)}.';
      })
      .join(' ');
  final fixes = shown
      .map(
        (phone) =>
            _contrastFix(phone.expected, phone.heard, phone.at) ??
            _genericFix(phone),
      )
      .join(' ');

  final reading = correctReading.isEmpty
      ? 'Эталон — /${word.expected}/.'
      : 'Эталон /${word.expected}/ читается примерно как «$correctReading».';
  return PronunciationHint(
    correctReading: correctReading,
    heardReading: heardReading,
    correct: [
      reading,
      ?stress,
      correctDetails,
    ].where((part) => part.isNotEmpty).join(' '),
    heard: word.heard.isEmpty
        ? 'Система не разобрала слово.'
        : 'У вас прозвучало /${word.heard}/'
              '${heardReading.isEmpty ? '' : ', примерно «$heardReading»'}. '
              '$heardDetails',
    fix: fixes,
  );
}

/// Learner spelling of an IPA string. A stress mark stresses the next vowel.
String roughReading(String ipa) {
  final buffer = StringBuffer();
  var stressNext = false;
  for (final phone in _phones(ipa)) {
    if (phone == 'ˈ') {
      stressNext = true;
      continue;
    }
    if (phone == 'ˌ' || phone == '.') continue;
    final piece = _approximations[phone] ?? _approximations[_base(phone)];
    if (piece == null) continue;
    buffer.write(
      stressNext && _vowels.contains(_base(phone)) ? _stressed(piece) : piece,
    );
    stressNext = false;
  }
  return buffer.toString();
}

const _multiPhones = [
  'tʃ',
  'dʒ',
  'eɪ',
  'aɪ',
  'ɔɪ',
  'aʊ',
  'oʊ',
  'əʊ',
  'eə',
  'ɪə',
  'ʊə',
  'iː',
  'uː',
  'ɑː',
  'ɔː',
  'ɜː',
];

List<String> _phones(String ipa) {
  final phones = <String>[];
  var index = 0;
  while (index < ipa.length) {
    final mark = ipa[index];
    if (mark == 'ˈ' || mark == 'ˌ' || mark == '.') {
      phones.add(mark);
      index++;
      continue;
    }
    String? matched;
    for (final phone in _multiPhones) {
      if (ipa.startsWith(phone, index)) {
        matched = phone;
        break;
      }
    }
    if (matched != null) {
      phones.add(matched);
      index += matched.length;
    } else {
      phones.add(mark);
      index++;
    }
  }
  return phones;
}

String _base(String phone) => phone.replaceAll('ː', '');

String? _stressSentence(String ipa) {
  final phones = _phones(ipa);
  var vowel = 0;
  var stressed = 0;
  var pending = false;
  var found = false;
  for (final phone in phones) {
    if (phone == 'ˈ' || phone == 'ˌ') {
      pending = phone == 'ˈ';
      continue;
    }
    if (!_vowels.contains(_base(phone))) continue;
    vowel++;
    if (pending) {
      stressed = vowel;
      found = true;
      pending = false;
    }
  }
  if (!found) return null;
  return 'Ударение на ${_ordinal(stressed)} слоге.';
}

String _ordinal(int index) {
  const names = ['первом', 'втором', 'третьем', 'четвёртом', 'пятом', 'шестом'];
  if (index >= 1 && index <= names.length) return names[index - 1];
  return '$index-м';
}

String _place(String at) {
  return switch (at) {
    'start' => 'В начале',
    'end' => 'В конце',
    'only' => 'Здесь',
    _ => 'В середине',
  };
}

String _describeSound(String phone) {
  return _soundGuides[_base(phone)] ?? 'звук «${soundSpelling(phone)}»';
}

String? _contrastFix(String expected, String heard, String at) {
  final key = '${_base(expected)}>${_base(heard)}';
  final where = switch (at) {
    'start' => 'в начале',
    'end' => 'в конце',
    _ => 'в этом месте',
  };
  return switch (key) {
    'ə>ɪ' || 'ə>i' =>
      'Сделайте гласную $where максимально короткой и расслабленной. '
          'Это шва: смазанный звук между «а» и «э», без отчётливого «и».',
    'ɪ>ə' =>
      'Здесь нужен краткий ясный «и», как в sit, а не совсем стёртый звук.',
    'ɪ>i' => 'Не тяните «и» $where. Он короткий, как в sit, а не как в see.',
    'i>ɪ' => 'Потяните «и» $where: это долгий звук, как в see.',
    'θ>s' || 'θ>t' || 'θ>f' =>
      'Не подменяйте th звуком «${soundSpelling(heard)}». '
          'Кончик языка слегка между зубами, выдохните без свиста и без удара.',
    'ð>z' || 'ð>d' || 'ð>v' =>
      'Это звонкий th. Язык между зубами и с голосом, '
          'а не «${soundSpelling(heard)}».',
    'æ>e' ||
    'æ>ɛ' ||
    'æ>ə' => 'Откройте рот шире: это плоское «э», как в cat, а не обычное «е».',
    'ŋ>n' => 'В конце должен слышаться носовой «нг», без отдельного «г».',
    _ => null,
  };
}

String _genericFix(PhoneSlip phone) {
  final where = switch (phone.at) {
    'start' => 'в начале',
    'end' => 'в конце',
    _ => 'здесь',
  };
  if (phone.heard.isEmpty) {
    return 'Добавьте $where ${_describeSound(phone.expected)}.';
  }
  return 'Поправьте звук $where: нужен ${_describeSound(phone.expected)}, '
      'а получился ${_describeSound(phone.heard)}.';
}

String _stressed(String value) {
  if (value.isEmpty) return value;
  return '${value[0]}\u0301${value.substring(1)}';
}

const _vowels = {
  'ɪ',
  'i',
  'ʊ',
  'u',
  'æ',
  'ɛ',
  'e',
  'ɑ',
  'a',
  'ʌ',
  'ə',
  'ɚ',
  'ɝ',
  'ɜ',
  'ɔ',
  'o',
  'eɪ',
  'aɪ',
  'ɔɪ',
  'aʊ',
  'oʊ',
  'əʊ',
};

const _approximations = <String, String>{
  'θ': 'т',
  'ð': 'з',
  'ʃ': 'ш',
  'ʒ': 'ж',
  'tʃ': 'ч',
  'dʒ': 'дж',
  'ŋ': 'нг',
  'ɹ': 'р',
  'r': 'р',
  'j': 'й',
  'ɡ': 'г',
  'g': 'г',
  'eɪ': 'эй',
  'aɪ': 'ай',
  'ɔɪ': 'ой',
  'aʊ': 'ау',
  'oʊ': 'оу',
  'əʊ': 'оу',
  'ɪ': 'и',
  'i': 'и',
  'ʊ': 'у',
  'u': 'у',
  'æ': 'э',
  'ɛ': 'е',
  'e': 'е',
  'ɑ': 'а',
  'a': 'а',
  'ʌ': 'а',
  'ə': 'э',
  'ɚ': 'эр',
  'ɝ': 'эр',
  'ɜ': 'ё',
  'ɔ': 'о',
  'o': 'о',
  'p': 'п',
  'b': 'б',
  't': 'т',
  'd': 'д',
  'k': 'к',
  'f': 'ф',
  'v': 'в',
  's': 'с',
  'z': 'з',
  'h': 'х',
  'm': 'м',
  'n': 'н',
  'l': 'л',
  'w': 'в',
};

const _soundGuides = <String, String>{
  'ə':
      'шва — очень короткий безударный звук между «а» и «э», как в конце about',
  'ɪ': 'краткий «и», как в sit: короче обычного русского «и»',
  'i': 'долгий «и», как в see',
  'ʊ': 'краткий «у», как в book',
  'u': 'долгий «у», как в food',
  'æ': 'открытое «э», как в cat: рот шире, чем для обычного «е»',
  'ɛ': 'короткое «е», как в bed',
  'e': 'короткое «е»',
  'ɑ': 'открытое «а», как в father',
  'ʌ': 'короткое «а», как в cup',
  'ɔ': 'огублённое «о», как в thought',
  'θ': 'глухой межзубный th: язык между зубами, без свиста',
  'ð': 'звонкий межзубный th, как в this',
  'ʃ': 'мягкое «ш», как в she',
  'ŋ': 'носовой «нг»: воздух идёт через нос, отдельного «г» нет',
  'ɹ': 'английский r: язык не дрожит',
  'eɪ': 'двойной «эй», как в day',
  'aɪ': 'двойной «ай», как в my',
  'oʊ': 'двойной «оу», как в go',
  'əʊ': 'двойной «оу», как в go',
  'aʊ': 'двойной «ау», как в now',
};
