/// Invisible suffix so a reaction can stay on the Google/Noto path
/// instead of being remapped to a Kolobok pack file.
///
/// U+2060 WORD JOINER is not stripped by JS/Dart [trim], and the server
/// keeps it (`slice(0, 16)`). Older clients that ignore the mark still
/// show the Unicode glyph.
const kGoogleEmojiMark = '\u2060';

bool isGoogleEmojiStyle(String emoji) => emoji.contains(kGoogleEmojiMark);

String markGoogleEmoji(String emoji) {
  final trimmed = emoji.trim();
  if (trimmed.isEmpty) return trimmed;
  if (trimmed.contains(kGoogleEmojiMark)) return trimmed;
  return '$trimmed$kGoogleEmojiMark';
}

/// Glyph to paint — strips the Google-style mark.
String displayEmoji(String emoji) =>
    emoji.trim().replaceAll(kGoogleEmojiMark, '');
