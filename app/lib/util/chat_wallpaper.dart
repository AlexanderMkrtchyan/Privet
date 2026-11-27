import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

/// How a chat background is painted.
enum ChatWallpaperKind { none, doodle, soft, custom }

/// Pixel pack for doodle themes. Mobile stays portrait; Linux picks FHD or 2K.
enum ChatWallpaperPack { mobile, fhd, qhd }

/// One chat background the user can pick in Appearance.
class ChatWallpaper {
  const ChatWallpaper({
    required this.id,
    required this.label,
    required this.kind,
    this.darkAsset,
    this.lightAsset,
    this.darkTint,
    this.lightTint,
  });

  final String id;
  final String label;
  final ChatWallpaperKind kind;
  final String? darkAsset;
  final String? lightAsset;

  /// Base tone for [ChatWallpaperKind.soft] (painted gradient, no assets).
  final Color? darkTint;
  final Color? lightTint;

  /// Soft tone used at [brightness], if this is a soft-color wallpaper.
  Color? tintFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkTint : lightTint;

  /// Asset used at [brightness] for [pack].
  String? assetFor(
    Brightness brightness, [
    ChatWallpaperPack pack = ChatWallpaperPack.mobile,
  ]) {
    final base = brightness == Brightness.dark ? darkAsset : lightAsset;
    if (base == null) return null;
    if (pack == ChatWallpaperPack.mobile) return base;
    const marker = 'assets/wallpapers/doodles/';
    if (!base.startsWith(marker)) return base;
    final folder = pack == ChatWallpaperPack.qhd ? '2k' : 'fhd';
    return '$marker$folder/${base.substring(marker.length)}';
  }
}

/// FHD on 1080p windows, 2K when the window is QHD or larger. Phones stay mobile.
ChatWallpaperPack chatWallpaperPackFor(Size physicalSize) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
      break;
    default:
      return ChatWallpaperPack.mobile;
  }
  if (physicalSize.longestSide >= 2400 || physicalSize.shortestSide >= 1300) {
    return ChatWallpaperPack.qhd;
  }
  return ChatWallpaperPack.fhd;
}

/// Built-in chat backgrounds: habitation doodle themes (math, physics, …).
class ChatWallpaperCatalog {
  ChatWallpaperCatalog._();

  static const noneId = 'none';
  static const customId = 'custom';

  static const none = ChatWallpaper(
    id: noneId,
    label: 'None',
    kind: ChatWallpaperKind.none,
  );

  static const custom = ChatWallpaper(
    id: customId,
    label: 'Your photo',
    kind: ChatWallpaperKind.custom,
  );

  static const List<ChatWallpaper> doodles = [
    ChatWallpaper(
      id: 'doodle:math',
      label: 'Math',
      kind: ChatWallpaperKind.doodle,
      darkAsset: 'assets/wallpapers/doodles/math-dark.jpg',
      lightAsset: 'assets/wallpapers/doodles/math-light.jpg',
    ),
    ChatWallpaper(
      id: 'doodle:physics',
      label: 'Physics',
      kind: ChatWallpaperKind.doodle,
      darkAsset: 'assets/wallpapers/doodles/physics-dark.jpg',
      lightAsset: 'assets/wallpapers/doodles/physics-light.jpg',
    ),
    ChatWallpaper(
      id: 'doodle:code',
      label: 'Code',
      kind: ChatWallpaperKind.doodle,
      darkAsset: 'assets/wallpapers/doodles/code-dark.jpg',
      lightAsset: 'assets/wallpapers/doodles/code-light.jpg',
    ),
    ChatWallpaper(
      id: 'doodle:date',
      label: 'Dating',
      kind: ChatWallpaperKind.doodle,
      darkAsset: 'assets/wallpapers/doodles/date-dark.jpg',
      lightAsset: 'assets/wallpapers/doodles/date-light.jpg',
    ),
    ChatWallpaper(
      id: 'doodle:work',
      label: 'Work',
      kind: ChatWallpaperKind.doodle,
      darkAsset: 'assets/wallpapers/doodles/work-dark.jpg',
      lightAsset: 'assets/wallpapers/doodles/work-light.jpg',
    ),
    ChatWallpaper(
      id: 'doodle:space',
      label: 'Space',
      kind: ChatWallpaperKind.doodle,
      darkAsset: 'assets/wallpapers/doodles/space-dark.jpg',
      lightAsset: 'assets/wallpapers/doodles/space-light.jpg',
    ),
  ];

  /// Soft solid tones — pastel in light mode, deep desaturated in dark mode.
  /// Painted in code (no image assets), so they stay crisp at any size.
  static const List<ChatWallpaper> softColors = [
    ChatWallpaper(
      id: 'soft:blue',
      label: 'Blue',
      kind: ChatWallpaperKind.soft,
      darkTint: Color(0xFF101B29),
      lightTint: Color(0xFFDCE9FA),
    ),
    ChatWallpaper(
      id: 'soft:mint',
      label: 'Mint',
      kind: ChatWallpaperKind.soft,
      darkTint: Color(0xFF0F1D18),
      lightTint: Color(0xFFDDF1E6),
    ),
    ChatWallpaper(
      id: 'soft:lavender',
      label: 'Lavender',
      kind: ChatWallpaperKind.soft,
      darkTint: Color(0xFF171327),
      lightTint: Color(0xFFEAE4F9),
    ),
    ChatWallpaper(
      id: 'soft:rose',
      label: 'Rose',
      kind: ChatWallpaperKind.soft,
      darkTint: Color(0xFF201219),
      lightTint: Color(0xFFFAE1E8),
    ),
    ChatWallpaper(
      id: 'soft:sand',
      label: 'Sand',
      kind: ChatWallpaperKind.soft,
      darkTint: Color(0xFF1D1810),
      lightTint: Color(0xFFF7EBD5),
    ),
    ChatWallpaper(
      id: 'soft:sage',
      label: 'Sage',
      kind: ChatWallpaperKind.soft,
      darkTint: Color(0xFF131C11),
      lightTint: Color(0xFFE4EEDC),
    ),
  ];

  static ChatWallpaper byId(String? id) {
    if (id == null || id.isEmpty || id == noneId) return none;
    if (id == customId) return custom;
    for (final wall in doodles) {
      if (wall.id == id) return wall;
    }
    for (final wall in softColors) {
      if (wall.id == id) return wall;
    }
    return none;
  }

  static bool isKnown(String id) => byId(id).id == id;
}

/// Image (asset, soft gradient or custom bytes) for a wallpaper choice.
Widget chatWallpaperImage({
  required ChatWallpaper wall,
  required Brightness brightness,
  Uint8List? customBytes,
  ChatWallpaperPack pack = ChatWallpaperPack.mobile,
  BoxFit fit = BoxFit.cover,
}) {
  if (wall.kind == ChatWallpaperKind.soft) {
    return ChatSoftWallpaper(wall: wall, brightness: brightness);
  }
  if (wall.kind == ChatWallpaperKind.custom) {
    if (customBytes == null || customBytes.isEmpty) {
      return const SizedBox.expand();
    }
    return Image.memory(
      customBytes,
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      width: double.infinity,
      height: double.infinity,
    );
  }
  final asset = wall.assetFor(brightness, pack);
  if (asset == null) return const SizedBox.expand();

  return Image.asset(
    asset,
    fit: fit,
    gaplessPlayback: true,
    filterQuality: FilterQuality.medium,
    width: double.infinity,
    height: double.infinity,
    errorBuilder: (_, error, stack) => const SizedBox.expand(),
  );
}

/// Painted soft-tone background: a gentle diagonal wash plus a top-left glow.
/// Light mode gets pastel tones, dark mode deep desaturated ones, so bubbles
/// and text keep their regular contrast.
class ChatSoftWallpaper extends StatelessWidget {
  const ChatSoftWallpaper({
    super.key,
    required this.wall,
    required this.brightness,
  });

  final ChatWallpaper wall;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final dark = brightness == Brightness.dark;
    final tint = wall.tintFor(brightness) ??
        (dark ? const Color(0xFF141A20) : const Color(0xFFEEF3F8));
    final hsl = HSLColor.fromColor(tint);
    final spread = dark ? 0.035 : 0.10;
    final top = hsl
        .withLightness((hsl.lightness + spread).clamp(0.0, 1.0))
        .toColor();
    final end = hsl
        .withLightness((hsl.lightness - spread * 0.8).clamp(0.0, 1.0))
        .toColor();
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [top, tint, end],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.65, -0.75),
              radius: 1.2,
              colors: [
                Colors.white.withValues(alpha: dark ? 0.06 : 0.55),
                Colors.white.withValues(alpha: 0.0),
              ],
            ),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
