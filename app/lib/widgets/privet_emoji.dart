import 'package:animated_emoji/animated_emoji.dart';
import 'package:flutter/material.dart';

/// Global switch flipped by [PrivetState.lowResourceMode]. When true, skip
/// network Lottie emoji entirely (static unicode glyphs only).
bool privetLowResourceEmoji = false;

/// Renders a Noto animated emoji when available; falls back to the unicode glyph.
///
/// Defaults are deliberately cheap: [animate] plays exactly once on mount and
/// [repeat] is `false`. Continuous Lottie loops in a chat (reactions, inline
/// emoji, big emoji messages) force per-frame vector redraws forever, which
/// pegs the Flutter render pipeline against vsync and — on Linux/GTK — starves
/// the X11 compositor so *other* windows also stutter. Opt into `repeat: true`
/// only for one-off flourishes (e.g. celebratory big emoji on hover).
///
/// Emoji rendered smaller than [staticGlyphThreshold] fall back to the plain
/// unicode glyph: the animation is imperceptible at that size and pulling a
/// Lottie composition per reaction badge is pure overhead.
class PrivetEmoji extends StatelessWidget {
  const PrivetEmoji(
    this.emoji, {
    super.key,
    this.size = 24,
    this.repeat = false,
    this.animate = true,
  });

  final String emoji;
  final double size;
  final bool repeat;
  final bool animate;

  /// Below this pixel size we skip Lottie entirely and use the unicode glyph.
  /// Reaction menu chips are 26px — keep them static too on modest hardware.
  static const double staticGlyphThreshold = 28;

  @override
  Widget build(BuildContext context) {
    final trimmed = emoji.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    Widget glyphFallback() => Text(
      trimmed,
      style: TextStyle(fontSize: size, height: 1),
      textAlign: TextAlign.center,
    );

    if (privetLowResourceEmoji || size < staticGlyphThreshold) {
      return glyphFallback();
    }

    final data =
        AnimatedEmojis.fromEmojiString(trimmed) ??
        AnimatedEmojis.fromEmojiString(_stripVs(trimmed));

    if (data == null) return glyphFallback();

    return AnimatedEmoji(
      data,
      size: size,
      repeat: repeat,
      animate: animate,
      source: AnimatedEmojiSource.network,
      errorWidget: glyphFallback(),
    );
  }

  /// Strip variation selectors / ZWJ noise that break id matching.
  static String _stripVs(String raw) {
    return raw.replaceAll(RegExp(r'[\uFE0E\uFE0F]'), '');
  }
}
