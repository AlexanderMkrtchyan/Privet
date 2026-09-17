import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/kolobok_images.dart';
import '../util/kolobok_smileys.dart';
import '../util/low_resource.dart';
import 'kolobok_smiley.dart';

/// Single-line (or clipped) plain text with Kolobok art for mapped smileys.
///
/// Chat bodies paint smileys via [TextPainter]; list previews and reply bars
/// are ordinary [Text], so without this they fall back to the system colour
/// emoji font. Ready frames swap in as [KolobokImageCache.generationListenable]
/// advances — until then the Unicode glyph stays visible.
class KolobokPlainText extends StatelessWidget {
  const KolobokPlainText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;

  static bool _warmedLight = false;
  static bool _warmedDark = false;

  static void _ensureWarm({required bool light}) {
    if (privetLowResource) return;
    if (light) {
      if (_warmedLight) return;
      _warmedLight = true;
    } else {
      if (_warmedDark) return;
      _warmedDark = true;
    }
    KolobokImageCache.instance.preload(
      kolobokSmileys.map((entry) => entry.file),
      light: light,
    );
  }

  @override
  Widget build(BuildContext context) {
    final light = PrivetTheme.isLight;
    _ensureWarm(light: light);

    return ListenableBuilder(
      listenable: KolobokImageCache.instance.generationListenable,
      builder: (context, _) {
        return Text.rich(
          TextSpan(style: style, children: _spans(light)),
          maxLines: maxLines,
          overflow: overflow,
        );
      },
    );
  }

  List<InlineSpan> _spans(bool light) {
    if (text.isEmpty) return const [];
    if (privetLowResource) return [TextSpan(text: text)];

    final cache = KolobokImageCache.instance;
    final em = style?.fontSize ?? 13.0;
    // Slightly larger than the text so smileys read like chat-body art.
    final emojiSize = em * 1.15;
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString()));
      buffer.clear();
    }

    for (final grapheme in text.characters) {
      final file = kolobokFileForEmoji(grapheme);
      if (file == null || !cache.isReady(file, light: light)) {
        // Kick decode so generationListenable can rebuild once the art lands.
        if (file != null) cache.frameFor(file, light: light, animate: false);
        buffer.write(grapheme);
        continue;
      }
      flush();
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: KolobokSmiley(
            file,
            size: emojiSize,
            animate: false,
            showHalo: false,
            semanticLabel: grapheme,
          ),
        ),
      );
    }
    flush();
    return spans;
  }
}
