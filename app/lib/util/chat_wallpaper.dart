import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

/// How a chat background is painted.
enum ChatWallpaperKind { none, doodle, custom }

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
  });

  final String id;
  final String label;
  final ChatWallpaperKind kind;
  final String? darkAsset;
  final String? lightAsset;

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

  static ChatWallpaper byId(String? id) {
    if (id == null || id.isEmpty || id == noneId) return none;
    if (id == customId) return custom;
    for (final wall in doodles) {
      if (wall.id == id) return wall;
    }
    return none;
  }

  static bool isKnown(String id) => byId(id).id == id;
}

/// Image (asset or custom bytes) for a wallpaper choice.
Widget chatWallpaperImage({
  required ChatWallpaper wall,
  required Brightness brightness,
  Uint8List? customBytes,
  ChatWallpaperPack pack = ChatWallpaperPack.mobile,
  BoxFit fit = BoxFit.cover,
}) {
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
