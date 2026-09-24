import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/kolobok_images.dart';
import '../util/kolobok_smileys.dart';

/// One bundled Kolobok smiley (classic ICQ-era artwork).
///
/// The light and dark packs are different drawings, not a tint, so the asset
/// is resolved from [PrivetTheme.isLight] on every build — a theme switch
/// re-reads it without extra state.
///
/// Playback goes through [KolobokImageCache] so this widget and the inline
/// painter in message text stay on the same clock. Pass [animate]: false to
/// freeze on the first frame.
///
/// On dark UI a soft white radial disc sits behind the art so black hair /
/// outlines stay readable against the charcoal background.
class KolobokSmiley extends StatefulWidget {
  const KolobokSmiley(
    this.file, {
    super.key,
    this.size = 24,
    this.semanticLabel,
    this.animate = true,
    this.showHalo,
  });

  /// Pack basename without extension, e.g. `smile`. See [kolobokSmileys].
  final String file;

  final double size;

  /// Defaults to the smiley's Unicode equivalent, for screen readers.
  final String? semanticLabel;

  /// When false, only the first decoded frame shows.
  final bool animate;

  /// Soft white glow behind the art. Defaults to on when the app theme is dark.
  final bool? showHalo;

  @override
  State<KolobokSmiley> createState() => _KolobokSmileyState();
}

class _KolobokSmileyState extends State<KolobokSmiley> {
  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      KolobokImageCache.instance.addListener(_onTick);
    }
    KolobokImageCache.instance.frameFor(
      widget.file,
      light: PrivetTheme.isLight,
      animate: widget.animate,
    );
  }

  @override
  void didUpdateWidget(covariant KolobokSmiley oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate == widget.animate) return;
    if (widget.animate) {
      KolobokImageCache.instance.addListener(_onTick);
    } else {
      KolobokImageCache.instance.removeListener(_onTick);
    }
  }

  @override
  void dispose() {
    if (widget.animate) {
      KolobokImageCache.instance.removeListener(_onTick);
    }
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final image = KolobokImageCache.instance.frameFor(
      widget.file,
      light: PrivetTheme.isLight,
      animate: widget.animate,
    );
    final label = widget.semanticLabel ?? kolobokEmojiForFile(widget.file);
    final halo = widget.showHalo ?? !PrivetTheme.isLight;
    final box = widget.size;
    // Large sticker-size smileys: keep the halo inside the layout box on
    // Android/Linux so it cannot paint over the message timestamp / nearby text.
    final constrainBig = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows) &&
        box >= 48;
    final haloExtent = constrainBig ? box : box * 1.35;

    if (image == null) {
      return SizedBox(
        width: box,
        height: box,
        child: label == null
            ? null
            : Semantics(label: label, child: const SizedBox.expand()),
      );
    }

    return Semantics(
      label: label,
      child: SizedBox(
        width: box,
        height: box,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: constrainBig ? Clip.hardEdge : Clip.none,
          children: [
            if (halo)
              IgnorePointer(
                child: Container(
                  width: haloExtent,
                  height: haloExtent,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Color(0xE6FFFFFF), // ~90% white at center
                        Color(0x66FFFFFF), // ~40%
                        Color(0x00FFFFFF), // transparent at edge
                      ],
                      stops: [0.0, 0.42, 1.0],
                    ),
                  ),
                ),
              ),
            RawImage(
              image: image,
              width: box,
              height: box,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              isAntiAlias: true,
            ),
          ],
        ),
      ),
    );
  }
}
