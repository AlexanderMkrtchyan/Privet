import 'dart:async';

import 'package:flutter/material.dart';

import '../util/noto_color_emoji.dart';

/// Linux-identical Noto Color Emoji bitmap (bundled CBDT strike).
class NotoColorEmoji extends StatelessWidget {
  const NotoColorEmoji(
    this.emoji, {
    super.key,
    this.size = 24,
  });

  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cache = NotoColorEmojiCache.instance;
    unawaited(cache.ensureLoaded());
    return ListenableBuilder(
      listenable: cache,
      builder: (context, _) {
        final image = cache.imageFor(emoji);
        if (image == null) {
          return Text(
            emoji,
            style: TextStyle(
              fontSize: size,
              height: 1,
              leadingDistribution: TextLeadingDistribution.even,
            ),
            textAlign: TextAlign.center,
          );
        }
        return RawImage(
          image: image,
          width: size,
          height: size,
          filterQuality: FilterQuality.high,
        );
      },
    );
  }
}
