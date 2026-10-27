import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/chat_wallpaper.dart';

/// Fills the message list with the chosen chat background.
class ChatWallpaperLayer extends StatelessWidget {
  const ChatWallpaperLayer({
    super.key,
    required this.wallpaperId,
    this.customBytes,
  });

  final String wallpaperId;
  final Uint8List? customBytes;

  @override
  Widget build(BuildContext context) {
    final wall = ChatWallpaperCatalog.byId(wallpaperId);
    if (wall.kind == ChatWallpaperKind.none) {
      return const SizedBox.shrink();
    }
    if (wall.kind == ChatWallpaperKind.custom &&
        (customBytes == null || customBytes!.isEmpty)) {
      return const SizedBox.shrink();
    }
    final brightness = PrivetTheme.isLight ? Brightness.light : Brightness.dark;
    final pack = chatWallpaperPackFor(View.of(context).physicalSize);
    final scrim = wall.kind == ChatWallpaperKind.custom
        ? (PrivetTheme.isLight
            ? const Color(0x14000000)
            : const Color(0x2E000000))
        : null;
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            chatWallpaperImage(
              wall: wall,
              brightness: brightness,
              customBytes: customBytes,
              pack: pack,
            ),
            if (scrim != null) ColoredBox(color: scrim),
          ],
        ),
      ),
    );
  }
}
