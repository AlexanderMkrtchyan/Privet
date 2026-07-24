import 'package:animated_emoji/animated_emoji.dart';
import 'package:flutter/material.dart';

/// Renders a Noto animated emoji when available; falls back to the unicode glyph.
class PrivetEmoji extends StatelessWidget {
  const PrivetEmoji(
    this.emoji, {
    super.key,
    this.size = 24,
    this.repeat = true,
    this.animate = true,
  });

  final String emoji;
  final double size;
  final bool repeat;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final trimmed = emoji.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    final data = AnimatedEmojis.fromEmojiString(trimmed) ??
        AnimatedEmojis.fromEmojiString(_stripVs(trimmed));

    if (data == null) {
      return Text(
        trimmed,
        style: TextStyle(fontSize: size, height: 1),
        textAlign: TextAlign.center,
      );
    }

    return AnimatedEmoji(
      data,
      size: size,
      repeat: repeat,
      animate: animate,
      source: AnimatedEmojiSource.network,
      errorWidget: Text(
        trimmed,
        style: TextStyle(fontSize: size, height: 1),
      ),
    );
  }

  /// Strip variation selectors / ZWJ noise that break id matching.
  static String _stripVs(String raw) {
    return raw.replaceAll(RegExp(r'[\uFE0E\uFE0F]'), '');
  }
}
