import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/chat_wallpaper.dart';
import '../util/low_resource.dart';

/// Appearance grid: none, doodle themes, upload.
class ChatWallpaperPicker extends StatelessWidget {
  const ChatWallpaperPicker({
    super.key,
    required this.selectedId,
    required this.onSelect,
    required this.onUpload,
    this.customBytes,
  });

  final String selectedId;
  final Uint8List? customBytes;
  final ValueChanged<String> onSelect;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final hasCustom = customBytes != null && customBytes!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Chat wallpaper',
          style: TextStyle(
            color: PrivetTheme.mist,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        _grid(
          tiles: [
            const _Tile.none(),
            const _Tile.upload(),
            if (hasCustom) const _Tile.custom(),
          ],
        ),
        _section('Themes'),
        _grid(
          tiles: [
            for (final wall in ChatWallpaperCatalog.doodles) _Tile.wall(wall),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'On Linux the theme fills the chat at FHD or 2K from your display. '
          'Phones keep the portrait doodles. Upload sets your own picture.',
          style: TextStyle(color: PrivetTheme.mist, fontSize: 11),
        ),
      ],
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: PrivetTheme.mist,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _grid({required List<_Tile> tiles}) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: tiles.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.62,
      ),
      itemBuilder: (context, i) {
        final tile = tiles[i];
        final selected = selectedId == tile.id;
        return _WallpaperTile(
          tile: tile,
          selected: selected,
          customBytes: customBytes,
          onTap: () {
            if (tile.isUpload) {
              onUpload();
              return;
            }
            onSelect(tile.id);
          },
        );
      },
    );
  }
}

class _Tile {
  const _Tile.none()
    : id = ChatWallpaperCatalog.noneId,
      wall = ChatWallpaperCatalog.none,
      isUpload = false;

  _Tile.wall(this.wall) : id = wall.id, isUpload = false;

  const _Tile.custom()
    : id = ChatWallpaperCatalog.customId,
      wall = ChatWallpaperCatalog.custom,
      isUpload = false;

  const _Tile.upload()
    : id = '_upload',
      wall = ChatWallpaperCatalog.custom,
      isUpload = true;

  final String id;
  final ChatWallpaper wall;
  final bool isUpload;
}

class _WallpaperTile extends StatelessWidget {
  const _WallpaperTile({
    required this.tile,
    required this.selected,
    required this.onTap,
    this.customBytes,
  });

  final _Tile tile;
  final bool selected;
  final Uint8List? customBytes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = PrivetTheme.isLight ? Brightness.light : Brightness.dark;
    final label = tile.isUpload ? 'Upload' : tile.wall.label;
    return Tooltip(
      message: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: privetAnim(const Duration(milliseconds: 140)),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? PrivetTheme.signal : PrivetTheme.line,
                width: selected ? 2.5 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: PrivetTheme.panelElevated),
                if (tile.wall.kind == ChatWallpaperKind.none)
                  ColoredBox(color: PrivetTheme.ink)
                else if (tile.id == ChatWallpaperCatalog.customId &&
                    customBytes != null &&
                    customBytes!.isNotEmpty)
                  chatWallpaperImage(
                    wall: ChatWallpaperCatalog.custom,
                    brightness: brightness,
                    customBytes: customBytes,
                  )
                else if (!tile.isUpload)
                  chatWallpaperImage(
                    wall: tile.wall,
                    brightness: brightness,
                  ),
                if (tile.isUpload)
                  Center(
                    child: Icon(
                      Icons.add_photo_alternate_rounded,
                      color: PrivetTheme.paper,
                      size: 22,
                    ),
                  ),
                if (tile.wall.kind == ChatWallpaperKind.none)
                  Center(
                    child: Icon(
                      Icons.block_rounded,
                      color: PrivetTheme.mist,
                      size: 18,
                    ),
                  ),
                if (selected)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: PrivetTheme.signal,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
