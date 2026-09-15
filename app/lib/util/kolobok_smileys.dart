/// Bundled Kolobok smileys — the classic ICQ-era artwork by Ivan Mantsurov
/// (kolobanga.ru). 101 files ship for each background.
///
/// The light and dark packs are *distinct artwork*, not a tint, so the folder
/// is chosen from [PrivetTheme.isLight] at paint time (see [kolobokAssetPath]).
///
/// Messages travel as plain Unicode text — `expandEmoticons` already collapses
/// `:)` to 🙂 before sending — so a Kolobok smiley is identified by the emoji
/// it stands for. [kolobokFileForEmoji] maps a glyph back to a pack file;
/// glyphs not listed here keep the normal glyph / animated-emoji path.
///
/// Only smileys with a confident Unicode equivalent are listed. The remaining
/// files are still on disk and can be added as their meaning is confirmed.
class KolobokEntry {
  const KolobokEntry(this.file, this.emoji, [this.codes = const []]);

  /// Basename inside the pack, without the `.webp` extension.
  final String file;

  /// The Unicode emoji this smiley stands for. Several entries may share one
  /// glyph (e.g. `lol` and `rofl`); the first listed wins.
  final String emoji;

  /// Chat shortcuts that collapse to this smiley (`:)`, `*DRINK*`, …).
  /// Kept in sync with `emoticon_expand.dart` so both paths agree.
  final List<String> codes;
}

/// Curated subset of the pack, ordered so the most canonical file wins when
/// two smileys share a glyph.
const kolobokSmileys = <KolobokEntry>[
  // --- core faces ---------------------------------------------------------
  KolobokEntry('smile', '🙂', [':-)', ':)', '=)']),
  KolobokEntry('biggrin', '😃', [':-D', ':D']),
  KolobokEntry('lol', '😆', ['XD', 'xD']),
  KolobokEntry('rofl', '🤣'),
  KolobokEntry('girl_haha', '😂', ['*JOKINGLY*']),
  KolobokEntry('tease', '😛', [':-P', ':P']),
  KolobokEntry('wacko2', '😜'),
  KolobokEntry('mocking', '😝'),
  KolobokEntry('wink', '😉', [';-)', ';)']),
  KolobokEntry('flirt', '😏'),
  KolobokEntry('sarcastic', '😒'),
  KolobokEntry('blush', '😊', [':-[']),
  KolobokEntry('pleasantry', '😌'),
  KolobokEntry('angel', '😇', ['O:-)', 'O-)']),
  KolobokEntry('tender', '🥰'),

  // --- love ---------------------------------------------------------------
  KolobokEntry('girl_in_love', '😍', ['*IN LOVE*']),
  KolobokEntry('air_kiss', '😘', [':-*', ':-{}']),
  KolobokEntry('kiss3', '😚'),
  KolobokEntry('kiss2', '😗'),
  KolobokEntry('heart', '❤️', ['<3']),
  KolobokEntry('give_heart2', '💝'),
  KolobokEntry('give_rose', '🌹', ['@}->--']),
  KolobokEntry('mamba', '💃'),
  KolobokEntry('dance4', '🕺'),

  // --- sad / upset --------------------------------------------------------
  KolobokEntry('sad', '🙁', [':-(', ':(', '(sad)']),
  // Male crying Kolobok — keep classic cry shortcuts on this entry.
  KolobokEntry('cray', '😭', [":'-(", ":'(", ';(', '(cry)', '(sob)']),
  KolobokEntry('girl_cray2', '🥺'),
  KolobokEntry('sorry2', '😔'),
  KolobokEntry('girl_sigh', '😞'),
  KolobokEntry('scratch_one-s_head', '🤔', [r':-$']),
  KolobokEntry('girl_impossible', '🤨'),
  KolobokEntry('boredom', '🥱', ['*TIRED*']),
  KolobokEntry('lazy', '😴', ['(sleepy)']),
  KolobokEntry('moil', '😓'),

  // --- angry / shock ------------------------------------------------------
  KolobokEntry('ireful1', '😡', ['>:O']),
  KolobokEntry('spiteful', '😠'),
  KolobokEntry('bad', '😈', [']:->']),
  KolobokEntry('hysteric', '😱', [':-@']),
  KolobokEntry('shock', '😲', ['=-O']),
  KolobokEntry('scare', '😨'),
  KolobokEntry('crazy', '🤪', ['(headbang)']),
  KolobokEntry('vava', '🤕', ['(sick)']),
  KolobokEntry('secret', '🤫', [':-X', ':X']),
  KolobokEntry('boast', '😤'),
  KolobokEntry('fool', '🤡'),
  KolobokEntry('shout', '📢'),

  // --- hands / gestures ---------------------------------------------------
  KolobokEntry('yes3', '👍', ['*THUMBS UP*', '(yes)']),
  KolobokEntry('ok', '👌', ['(ok)']),
  KolobokEntry('clapping', '👏', ['(clap)']),
  KolobokEntry('thank_you2', '🙏'),
  KolobokEntry('pardon', '🙇'),
  KolobokEntry('curtsey', '🙇‍♀️'),
  KolobokEntry('stop', '✋', ['*STOP*']),
  KolobokEntry('this', '👉'),
  KolobokEntry('victory', '✌️'),
  KolobokEntry('feminist', '💪', ['(flex)']),
  KolobokEntry('friends', '🤝', ['(handshake)']),
  KolobokEntry('hi', '👋', ['(wave)']),
  KolobokEntry('bye', '👋'),
  KolobokEntry('preved', '🐻'),

  // --- objects ------------------------------------------------------------
  KolobokEntry('music', '🎵', ['(music)']),
  KolobokEntry('popcorn1', '🍿'),
  KolobokEntry('drinks', '🍺', ['*DRINK*', '(beer)']),
  KolobokEntry('girl_drink4', '🍸'),
  KolobokEntry('smoke', '🚬'),
  KolobokEntry('bomb', '💣', ['@=']),
  KolobokEntry('mail1', '✉️', ['(mail)']),
  KolobokEntry('search', '🔍'),
  KolobokEntry('focus', '🧐'),
  KolobokEntry('king', '👑'),
  KolobokEntry('big_boss', '😎', ['(cool)']),
  KolobokEntry('training1', '🏋️'),
  KolobokEntry('gamer4', '🎮'),
  KolobokEntry('paint2', '🎨'),
  KolobokEntry('beach', '🏖️'),
  KolobokEntry('beee', '🐝'),
  KolobokEntry('wizard', '🧙'),
  KolobokEntry('vampire', '🧛'),
  KolobokEntry('hunter', '🔫'),
  KolobokEntry('dirol', '🍬'),
  KolobokEntry('spruce_up', '💐'),
  KolobokEntry('unknown', '❓'),
  KolobokEntry('help', '🆘'),
  KolobokEntry('girl_hospital', '🏥'),
  KolobokEntry('dash1', '💨'),
  KolobokEntry('slow', '🐌'),
  KolobokEntry('party2', '🥳', ['(party)']),
  KolobokEntry('nea', '😻'),

  // --- remaining pack files ------------------------------------------------
  // Added so more of the pack is reachable. Where a glyph is already claimed
  // above, the earlier entry wins the reverse lookup; these still render when
  // picked directly by file name.
  KolobokEntry('i-m_so_happy', '😀'),
  KolobokEntry('mega_shock', '🤯'),
  KolobokEntry('aggressive', '🤬'),
  KolobokEntry('girl_crazy', '😵'),
  KolobokEntry('prankster2', '🙃'),
  KolobokEntry('yess', '🙌'),
  KolobokEntry('good', '✅'),
  KolobokEntry('punish', '🔨'),
  KolobokEntry('new_russian', '🤑'),
  KolobokEntry('yahoo', '🤠'),
  KolobokEntry('bb', '👋'),
  KolobokEntry('acute', '🤗', ['(hug)']),
  KolobokEntry('blum2', '😝'),
];

/// Glyph → pack file. Built once, tolerating variation selectors on the key.
final Map<String, String> _fileByEmoji = () {
  final map = <String, String>{};
  for (final smiley in kolobokSmileys) {
    map.putIfAbsent(smiley.emoji, () => smiley.file);
    map.putIfAbsent(stripEmojiVariation(smiley.emoji), () => smiley.file);
  }
  return map;
}();

/// Pack file for [emoji], or null when the pack has no equivalent.
String? kolobokFileForEmoji(String emoji) {
  final trimmed = emoji.trim();
  if (trimmed.isEmpty) return null;
  return _fileByEmoji[trimmed] ?? _fileByEmoji[stripEmojiVariation(trimmed)];
}

/// Glyph a pack [file] stands for, for accessibility labels.
String? kolobokEmojiForFile(String file) => _emojiByFile[file];

final Map<String, String> _emojiByFile = {
  for (final smiley in kolobokSmileys) smiley.file: smiley.emoji,
};

/// Drops `U+FE0E` / `U+FE0F` so `❤️` and `❤` resolve to the same file.
String stripEmojiVariation(String raw) =>
    raw.replaceAll(RegExp(r'[\uFE0E\uFE0F]'), '');

/// Asset path for [file] in the pack matching the current brightness.
///
/// The two packs are separate artwork with identical filenames.
String kolobokAssetPath(String file, {required bool light}) =>
    'assets/emoji/kolobok/${light ? 'light' : 'dark'}/$file.webp';
