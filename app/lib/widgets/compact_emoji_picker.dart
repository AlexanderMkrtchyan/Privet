import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../util/emoji_style.dart';
import '../util/kolobok_smileys.dart';
import '../util/low_resource.dart';
import '../util/noto_color_emoji.dart';
import 'kolobok_smiley.dart';
import 'noto_color_emoji.dart';

/// Composer emoji panel — dense Kolobok / Google tabs with a shared search.
///
/// Picking a Kolobok inserts the Unicode glyph it stands for; the chat
/// renderer maps that glyph back to the same art.
class CompactEmojiPicker extends StatefulWidget {
  const CompactEmojiPicker({
    super.key,
    required this.onSelected,
    this.height = 280,
    this.showDivider = true,
    this.textEditingController,
    this.onEditShortcodes,
    this.onPicked,
    this.markGooglePicks = false,
    this.dense = false,
  });

  final ValueChanged<String> onSelected;
  final double height;
  final bool showDivider;
  final TextEditingController? textEditingController;

  /// When true, Google-tab picks are marked so reactions stay on the
  /// Noto/Google path instead of remapping to Kolobok.
  final bool markGooglePicks;

  /// Tight overlay (message menu): skip the heavy EmojiPicker chrome and
  /// show a plain Google glyph grid.
  final bool dense;

  /// Opens the custom shortcode editor (Settings-style sheet).
  final VoidCallback? onEditShortcodes;

  /// Optional richer callback: [kolobokFile] is set only for pack picks.
  final void Function(String emoji, {String? kolobokFile})? onPicked;

  @override
  State<CompactEmojiPicker> createState() => _CompactEmojiPickerState();
}

enum _EmojiTab { kolobok, google }

/// Target cell size for picker grids. Keeping extent fixed (instead of a
/// capped column count) stops fullscreen / wide composer widths from
/// stretching gaps between emoji.
const double _emojiCellExtent = 34;

class _CompactEmojiPickerState extends State<CompactEmojiPicker> {
  _EmojiTab _tab = _EmojiTab.kolobok;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _insert(String emoji, {String? kolobokFile}) {
    final out = (kolobokFile == null && widget.markGooglePicks)
        ? markGoogleEmoji(emoji)
        : emoji;
    final controller = widget.textEditingController;
    if (controller != null) {
      final value = controller.value;
      final sel = value.selection;
      final start = sel.isValid ? sel.start : value.text.length;
      final end = sel.isValid ? sel.end : value.text.length;
      final next = value.text.replaceRange(start, end, out);
      controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + out.length),
      );
    }
    widget.onSelected(out);
    widget.onPicked?.call(out, kolobokFile: kolobokFile);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: PrivetTheme.panel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showDivider) Divider(height: 1, color: PrivetTheme.line),
          SizedBox(
            height: widget.height,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Column(
                children: [
                  _chromeBar(),
                  Expanded(
                    child: _tab == _EmojiTab.kolobok
                        ? _KolobokGrid(
                            query: _query,
                            dense: widget.dense,
                            onSelected: (file) {
                              final emoji = kolobokEmojiForFile(file);
                              if (emoji == null) return;
                              _insert(emoji, kolobokFile: file);
                            },
                          )
                        : _GooglePane(
                            height: widget.height - 48,
                            query: _query,
                            dense: widget.dense,
                            textEditingController:
                                widget.textEditingController,
                            onSelected: (emoji) {
                              if (widget.textEditingController == null) {
                                _insert(emoji);
                              } else {
                                widget.onSelected(emoji);
                                widget.onPicked?.call(emoji);
                              }
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chromeBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Row(
        children: [
          _TabChip(
            label: 'Kolobok',
            selected: _tab == _EmojiTab.kolobok,
            onTap: () => setState(() => _tab = _EmojiTab.kolobok),
          ),
          const SizedBox(width: 4),
          _TabChip(
            label: 'Google',
            selected: _tab == _EmojiTab.google,
            onTap: () => setState(() => _tab = _EmojiTab.google),
          ),
          if (widget.onEditShortcodes != null) ...[
            const SizedBox(width: 2),
            IconButton(
              tooltip: 'Custom shortcodes',
              mouseCursor: SystemMouseCursors.click,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                Icons.tune_rounded,
                size: 18,
                color: PrivetTheme.mist,
              ),
              onPressed: widget.onEditShortcodes,
            ),
          ],
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                onChanged: (v) => setState(() => _query = v.trim()),
                style: TextStyle(fontSize: 13, color: PrivetTheme.ink),
                cursorColor: PrivetTheme.signal,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: PrivetTheme.panelElevated,
                  hintText: _tab == _EmojiTab.kolobok
                      ? 'Search Kolobok…'
                      : 'Search emoji…',
                  hintStyle: TextStyle(fontSize: 13, color: PrivetTheme.mist),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: PrivetTheme.mist,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 32,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          mouseCursor: SystemMouseCursors.click,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          icon: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: PrivetTheme.mist,
                          ),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: PrivetTheme.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: PrivetTheme.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: PrivetTheme.signal),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? PrivetTheme.signal.withValues(alpha: 0.18)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        mouseCursor: SystemMouseCursors.click,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? PrivetTheme.signal : PrivetTheme.mist,
            ),
          ),
        ),
      ),
    );
  }
}

class _KolobokGrid extends StatelessWidget {
  const _KolobokGrid({
    required this.query,
    required this.onSelected,
    this.dense = false,
  });

  final String query;
  final ValueChanged<String> onSelected;
  final bool dense;

  List<KolobokEntry> _filtered() {
    final seen = <String>{};
    final out = <KolobokEntry>[];
    final q = query.toLowerCase();
    for (final entry in kolobokSmileys) {
      if (!seen.add(entry.file)) continue;
      if (q.isNotEmpty) {
        final hay = [
          entry.file,
          entry.emoji,
          ...entry.codes,
        ].join(' ').toLowerCase();
        if (!hay.contains(q)) continue;
      }
      out.add(entry);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filtered();
    final animate = !privetLowResource;

    if (entries.isEmpty) {
      return Center(
        child: Text(
          'No matches',
          style: TextStyle(fontSize: 13, color: PrivetTheme.mist),
        ),
      );
    }

    final cell = dense ? 46.0 : _emojiCellExtent;
    final smiley = dense ? 38.0 : 28.0;
    // Fixed cell size — never stretch with panel width (fullscreen used to
    // clamp columns at 14 and leave large gaps between 28px smileys).
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: cell,
        mainAxisSpacing: dense ? 2 : 0,
        crossAxisSpacing: dense ? 2 : 0,
        childAspectRatio: 1,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return Tooltip(
          message: '${entry.emoji}  ${entry.file}',
          waitDuration: const Duration(milliseconds: 400),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            mouseCursor: SystemMouseCursors.click,
            onTap: () {
              HapticFeedback.selectionClick();
              onSelected(entry.file);
            },
            child: Center(
              child: KolobokSmiley(
                entry.file,
                size: smiley,
                animate: animate,
                semanticLabel: entry.emoji,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GooglePane extends StatelessWidget {
  const _GooglePane({
    required this.height,
    required this.query,
    required this.onSelected,
    this.textEditingController,
    this.dense = false,
  });

  final double height;
  final String query;
  final ValueChanged<String> onSelected;
  final TextEditingController? textEditingController;
  final bool dense;

  List<Emoji> _searchHits(BuildContext context) {
    final q = query.toLowerCase();
    if (q.isEmpty) return const [];
    final cats = defaultEmojiSet;
    final out = <Emoji>[];
    final seen = <String>{};
    for (final cat in cats) {
      for (final e in cat.emoji) {
        if (!seen.add(e.emoji)) continue;
        final name = e.name.toLowerCase();
        if (name.contains(q) || e.emoji.contains(query)) {
          out.add(e);
          if (out.length >= 200) return out;
        }
      }
    }
    return out;
  }

  List<Emoji> _allGlyphs() {
    final out = <Emoji>[];
    final seen = <String>{};
    for (final cat in defaultEmojiSet) {
      for (final e in cat.emoji) {
        if (seen.add(e.emoji)) out.add(e);
      }
    }
    return out;
  }

  Widget _glyphGrid(List<Emoji> items) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          'No matches',
          style: TextStyle(fontSize: 13, color: PrivetTheme.mist),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _emojiCellExtent,
        mainAxisSpacing: 0,
        crossAxisSpacing: 0,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final e = items[index];
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          mouseCursor: SystemMouseCursors.click,
          onTap: () {
            HapticFeedback.selectionClick();
            final controller = textEditingController;
            if (controller != null) {
              final value = controller.value;
              final sel = value.selection;
              final start = sel.isValid ? sel.start : value.text.length;
              final end = sel.isValid ? sel.end : value.text.length;
              final next = value.text.replaceRange(start, end, e.emoji);
              controller.value = TextEditingValue(
                text: next,
                selection: TextSelection.collapsed(
                  offset: start + e.emoji.length,
                ),
              );
            }
            onSelected(e.emoji);
          },
          child: Center(
            child: useBundledNotoColorEmoji
                ? NotoColorEmoji(e.emoji, size: 24)
                : Text(e.emoji, style: const TextStyle(fontSize: 24)),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (query.isNotEmpty) {
      return _glyphGrid(_searchHits(context));
    }
    if (dense || useBundledNotoColorEmoji) {
      return _glyphGrid(_allGlyphs());
    }

    final clickCursor = WidgetStatePropertyAll(SystemMouseCursors.click);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols =
            (constraints.maxWidth / _emojiCellExtent).floor().clamp(1, 40);
        return Theme(
          data: Theme.of(context).copyWith(
            iconButtonTheme: IconButtonThemeData(
              style: ButtonStyle(mouseCursor: clickCursor),
            ),
            tabBarTheme: TabBarThemeData(mouseCursor: clickCursor),
          ),
          child: EmojiPicker(
            textEditingController: textEditingController,
            onEmojiSelected: (_, emoji) => onSelected(emoji.emoji),
            config: Config(
              height: height,
              checkPlatformCompatibility: !kIsWeb,
              viewOrderConfig: const ViewOrderConfig(
                top: EmojiPickerItem.categoryBar,
                middle: EmojiPickerItem.emojiView,
                bottom: EmojiPickerItem.searchBar,
              ),
              emojiViewConfig: EmojiViewConfig(
                columns: cols,
                emojiSizeMax: 26,
                verticalSpacing: 0,
                horizontalSpacing: 0,
                gridPadding: EdgeInsets.zero,
                backgroundColor: PrivetTheme.panel,
                noRecents: Text(
                  'No recent emoji',
                  style: TextStyle(fontSize: 13, color: PrivetTheme.mist),
                  textAlign: TextAlign.center,
                ),
                buttonMode: ButtonMode.NONE,
              ),
              categoryViewConfig: CategoryViewConfig(
                backgroundColor: PrivetTheme.panel,
                indicatorColor: PrivetTheme.signal,
                iconColorSelected: PrivetTheme.signal,
                iconColor: PrivetTheme.mist,
                dividerColor: PrivetTheme.line,
                recentTabBehavior: RecentTabBehavior.RECENT,
              ),
              // Shared top search covers filtering; keep a slim backspace row.
              bottomActionBarConfig: BottomActionBarConfig(
                enabled: true,
                showSearchViewButton: true,
                showBackspaceButton: true,
                backgroundColor: PrivetTheme.panelElevated,
                buttonColor: PrivetTheme.panelElevated,
                buttonIconColor: PrivetTheme.mist,
              ),
              searchViewConfig: SearchViewConfig(
                backgroundColor: PrivetTheme.panelElevated,
                buttonIconColor: PrivetTheme.mist,
                hintText: 'Search emoji',
                hintTextStyle: TextStyle(color: PrivetTheme.mist),
              ),
              skinToneConfig: SkinToneConfig(
                enabled: true,
                indicatorColor: PrivetTheme.signal,
              ),
            ),
          ),
        );
      },
    );
  }
}
