/// Live composer replacement for a completed emoticon token at the caret.
class EmoticonLiveExpand {
  const EmoticonLiveExpand({
    required this.replaceStart,
    required this.replaceEnd,
    required this.emoji,
  });

  final int replaceStart;
  final int replaceEnd;
  final String emoji;
}

/// Returns a live replacement when [cursor] sits right after a completed
/// emoticon token (e.g. `:)` → 🙂 while typing).
EmoticonLiveExpand? tryExpandEmoticonAtCursor(String text, int cursor) {
  if (cursor <= 0 || cursor > text.length) return null;

  final parenthetical = _tryExpandParentheticalAtCursor(text, cursor);
  if (parenthetical != null) return parenthetical;

  return _tryExpandWesternAtCursor(text, cursor);
}

EmoticonLiveExpand? _tryExpandParentheticalAtCursor(String text, int cursor) {
  if (cursor < 2 || text[cursor - 1] != ')') return null;

  var i = cursor - 2;
  while (i >= 0) {
    final ch = text[i];
    if (ch == ')') return null;
    if (ch == '(') break;
    if (!_isShortcodeChar(ch)) return null;
    i--;
  }
  if (i < 0 || text[i] != '(') return null;

  final token = text.substring(i, cursor);
  for (final entry in emoticonParenthetical) {
    if (token.toLowerCase() != entry.$1.toLowerCase()) continue;
    return EmoticonLiveExpand(
      replaceStart: i,
      replaceEnd: cursor,
      emoji: entry.$2,
    );
  }
  return null;
}

EmoticonLiveExpand? _tryExpandWesternAtCursor(String text, int cursor) {
  for (final entry in emoticonWestern) {
    final token = entry.$1;
    final len = token.length;
    if (cursor < len) continue;

    final start = cursor - len;
    final slice = text.substring(start, cursor);
    if (!_westernTokenMatches(slice, token)) continue;
    if (!_westernLiveExpandOk(text, start, cursor, token)) continue;

    return EmoticonLiveExpand(
      replaceStart: start,
      replaceEnd: cursor,
      emoji: entry.$2,
    );
  }
  return null;
}

bool _westernTokenMatches(String slice, String token) {
  if (slice.length != token.length) return false;
  return slice.toLowerCase() == token.toLowerCase();
}

bool _westernLiveExpandOk(String text, int start, int cursor, String token) {
  // `:/` is handled on send — live expansion fights http(s):// typing.
  if (token == ':/' || token == ':-/') return false;

  if (cursor < text.length && !_isEmoticonTailBoundary(text[cursor])) {
    return false;
  }
  return true;
}

bool _isEmoticonTailBoundary(String ch) {
  if (ch.length != 1) return true;
  final c = ch.codeUnitAt(0);
  final isLower = c >= 97 && c <= 122;
  final isUpper = c >= 65 && c <= 90;
  final isDigit = c >= 48 && c <= 57;
  return !(isLower || isUpper || isDigit);
}

bool _isShortcodeChar(String ch) {
  if (ch.length != 1) return false;
  final c = ch.codeUnitAt(0);
  final isLower = c >= 97 && c <= 122;
  final isUpper = c >= 65 && c <= 90;
  final isDigit = c >= 48 && c <= 57;
  return isLower || isUpper || isDigit;
}

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
