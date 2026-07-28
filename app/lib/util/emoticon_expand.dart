/// Expands text emoticons / shortcodes into Unicode emoji on send.
///
/// Supports western faces (`:D`, `:)`, `:(`, …) and parenthetical codes
/// (`(sob)`, `(smile)`, …) similar to classic Skype / Teams shortcuts.
String expandEmoticons(String input) {
  if (input.isEmpty) return input;

  var out = input;

  // Longer tokens first so `:-)` wins over `:)`, `(brokenheart)` over `(heart)`.
  for (final entry in emoticonParenthetical) {
    out = out.replaceAllMapped(
      RegExp(RegExp.escape(entry.$1), caseSensitive: false),
      (_) => entry.$2,
    );
  }

  for (final entry in emoticonWestern) {
    final token = entry.$1;
    final emoji = entry.$2;
    if (token == ':/') {
      // Do not turn `http://` / `https://` into a confused face.
      out = out.replaceAllMapped(RegExp(r':/(?!/)'), (_) => emoji);
    } else {
      out = out.replaceAllMapped(
        RegExp(RegExp.escape(token), caseSensitive: false),
        (_) => emoji,
      );
    }
  }

  return out;
}

/// Skype / Teams-style `(name)` codes. Sorted longest-first.
const emoticonParenthetical = <(String, String)>[
  ('(brokenheart)', '💔'),
  ('(facepalm)', '🤦'),
  ('(handshake)', '🤝'),
  ('(highfive)', '🙌'),
  ('(surprised)', '😲'),
  ('(speechless)', '😶'),
  ('(headbang)', '🤘'),
  ('(wasntme)', '🙈'),
  ('(talktothehand)', '✋'),
  ('(inlove)', '😍'),
  ('(worried)', '😟'),
  ('(sleepy)', '😴'),
  ('(monkey)', '🐵'),
  ('(party)', '🥳'),
  ('(punch)', '👊'),
  ('(devil)', '😈'),
  ('(angel)', '😇'),
  ('(think)', '🤔'),
  ('(shrug)', '🤷'),
  ('(smirk)', '😏'),
  ('(blush)', '😊'),
  ('(tongue)', '😛'),
  ('(music)', '🎵'),
  ('(movie)', '🎬'),
  ('(phone)', '📱'),
  ('(coffee)', '☕'),
  ('(heart)', '❤️'),
  ('(smile)', '🙂'),
  ('(happy)', '😄'),
  ('(laugh)', '😆'),
  ('(grin)', '😁'),
  ('(wink)', '😉'),
  ('(kiss)', '😘'),
  ('(cool)', '😎'),
  ('(nerd)', '🤓'),
  ('(yawn)', '🥱'),
  ('(whew)', '😮‍💨'),
  ('(sob)', '😭'),
  ('(cry)', '😢'),
  ('(sad)', '😞'),
  ('(angry)', '😠'),
  ('(swear)', '🤬'),
  ('(envy)', '😒'),
  ('(puke)', '🤮'),
  ('(sick)', '🤒'),
  ('(hug)', '🤗'),
  ('(rofl)', '🤣'),
  ('(lol)', '😂'),
  ('(wave)', '👋'),
  ('(clap)', '👏'),
  ('(flex)', '💪'),
  ('(fire)', '🔥'),
  ('(star)', '⭐'),
  ('(cake)', '🎂'),
  ('(beer)', '🍺'),
  ('(rain)', '🌧️'),
  ('(sun)', '☀️'),
  ('(call)', '📞'),
  ('(mail)', '✉️'),
  ('(time)', '⏰'),
  ('(wait)', '⏳'),
  ('(idea)', '💡'),
  ('(bandit)', '🥷'),
  ('(dog)', '🐶'),
  ('(cat)', '🐱'),
  ('(pig)', '🐷'),
  ('(yes)', '👍'),
  ('(no)', '👎'),
  ('(ok)', '👌'),
  ('(mm)', '😋'),
];

/// Western text faces. Sorted longest-first.
const emoticonWestern = <(String, String)>[
  (":'-(", '😢'),
  (":'(", '😢'),
  ('</3', '💔'),
  (':-D', '😃'),
  (':-)', '🙂'),
  (':-(', '😞'),
  (':-P', '😛'),
  (';-)', '😉'),
  (':-O', '😮'),
  (':-|', '😐'),
  (':-/', '😕'),
  ('^_^', '😊'),
  ('-_-', '😑'),
  ('T_T', '😭'),
  ('T.T', '😭'),
  ('o_O', '😳'),
  ('O_o', '😳'),
  ('<3', '❤️'),
  (':D', '😃'),
  (':)', '🙂'),
  (':(', '😞'),
  (':P', '😛'),
  (';)', '😉'),
  (':O', '😮'),
  (':|', '😐'),
  (':/', '😕'),
  (':3', '😊'),
  ('XD', '😆'),
  ('^^', '😊'),
];
