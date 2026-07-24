import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../theme.dart';

/// Composer emoji panel — large glyphs, tight grid (no extra padding).
class CompactEmojiPicker extends StatelessWidget {
  const CompactEmojiPicker({
    super.key,
    required this.onSelected,
    this.height = 192,
    this.showDivider = true,
    this.textEditingController,
  });

  final ValueChanged<String> onSelected;
  final double height;
  final bool showDivider;
  final TextEditingController? textEditingController;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: PrivetTheme.panel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDivider) const Divider(height: 1, color: PrivetTheme.line),
          SizedBox(
            height: height,
            child: EmojiPicker(
              textEditingController: textEditingController,
              onEmojiSelected: (_, emoji) {
                onSelected(emoji.emoji);
              },
              config: Config(
                height: height,
                checkPlatformCompatibility: !kIsWeb,
                // Size comes from emojiSizeMax; avoid TextStyle fontSize which
                // forces oversized cells / leftover padding.
                viewOrderConfig: const ViewOrderConfig(
                  top: EmojiPickerItem.categoryBar,
                  middle: EmojiPickerItem.emojiView,
                  bottom: EmojiPickerItem.searchBar,
                ),
                emojiViewConfig: const EmojiViewConfig(
                  columns: 10,
                  emojiSizeMax: 32,
                  verticalSpacing: 0,
                  horizontalSpacing: 0,
                  gridPadding: EdgeInsets.zero,
                  backgroundColor: PrivetTheme.panel,
                  noRecents: Text(
                    'No recent emoji',
                    style: TextStyle(fontSize: 14, color: PrivetTheme.mist),
                    textAlign: TextAlign.center,
                  ),
                  buttonMode: ButtonMode.MATERIAL,
                ),
                categoryViewConfig: const CategoryViewConfig(
                  backgroundColor: PrivetTheme.panel,
                  indicatorColor: PrivetTheme.signal,
                  iconColorSelected: PrivetTheme.signal,
                  iconColor: PrivetTheme.mist,
                  dividerColor: PrivetTheme.line,
                  recentTabBehavior: RecentTabBehavior.RECENT,
                ),
                bottomActionBarConfig: const BottomActionBarConfig(
                  backgroundColor: PrivetTheme.panelElevated,
                  buttonColor: PrivetTheme.panelElevated,
                  buttonIconColor: PrivetTheme.mist,
                  showBackspaceButton: true,
                ),
                searchViewConfig: const SearchViewConfig(
                  backgroundColor: PrivetTheme.panelElevated,
                  buttonIconColor: PrivetTheme.mist,
                  hintText: 'Search emoji',
                  hintTextStyle: TextStyle(color: PrivetTheme.mist),
                ),
                skinToneConfig: const SkinToneConfig(
                  enabled: true,
                  indicatorColor: PrivetTheme.signal,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
