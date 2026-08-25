import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import '../util/rich_text_markup.dart';

/// Opens the font-family popup anchored below/above [anchor] (the global rect
/// of the calling button). Resolves with the picked font key (empty string =
/// Default) or null when dismissed.
///
/// The popup is rendered as its own top-level [OverlayEntry], so it always
/// sits above every other floating layer (format bars, autocomplete popups,
/// composer overlays). Each row shows a readable label in the app font plus a
/// preview glyph in the actual typeface, so the names never get hidden by the
/// font itself.
Future<String?> showMessageFontPicker(
  BuildContext context, {
  required Rect anchor,
  required String? current,
}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return Future.value(null);
  final overlaySize = MediaQuery.sizeOf(context);
  final completer = Completer<String?>();
  // Remember who had focus so the composer / selection stays alive after the
  // menu closes (the menu itself grabs focus for Escape handling).
  final previousFocus = FocusManager.instance.primaryFocus;

  late final OverlayEntry entry;
  void close([String? value]) {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete(value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousFocus?.requestFocus();
    });
  }

  entry = OverlayEntry(
    builder: (_) => _FontPickerOverlay(
      anchor: anchor,
      screenSize: overlaySize,
      current: current ?? '',
      onPicked: (value) => close(value),
      onDismissed: () => close(),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _FontPickerOverlay extends StatelessWidget {
  const _FontPickerOverlay({
    required this.anchor,
    required this.screenSize,
    required this.current,
    required this.onPicked,
    required this.onDismissed,
  });

  final Rect anchor;
  final Size screenSize;
  final String current;
  final ValueChanged<String> onPicked;
  final VoidCallback onDismissed;

  static const double _menuWidth = 236;
  static const double _itemHeight = 42;

  @override
  Widget build(BuildContext context) {
    final entries = 1 + kMessageFonts.length; // "Default" + every family
    final menuHeight = _itemHeight * entries + 7; // + divider + padding
    // Keep the menu on-screen: cap its height and scroll when the list grows.
    final height = menuHeight < screenSize.height - 16
        ? menuHeight
        : screenSize.height - 16;

    // Prefer dropping below the anchor; flip above when there is no room.
    final placeBelow = anchor.bottom + 6 + height <= screenSize.height ||
        anchor.bottom >= anchor.top + height;
    final top = placeBelow
        ? anchor.bottom + 6
        : (anchor.top - 6 - height)
            .clamp(8.0, screenSize.height - height - 8.0);
    final left = anchor.left.clamp(
      8.0,
      (screenSize.width - _menuWidth - 8.0).clamp(8.0, screenSize.width),
    );

    return Stack(
      children: [
        // Full-screen tap barrier — anything outside the menu dismisses it.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismissed,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                onDismissed();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Material(
              color: PrivetTheme.panelElevated,
              elevation: 24,
              shadowColor: Colors.black87,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: PrivetTheme.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: _menuWidth,
                height: height,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _item(
                      value: '',
                      label: 'Default',
                      preview: null,
                      active: current.isEmpty,
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: PrivetTheme.line,
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final f in kMessageFonts)
                              _item(
                                value: f,
                                label: kMessageFontLabels[f] ?? f,
                                preview: f,
                                active: current == f,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _item({
    required String value,
    required String label,
    required String? preview,
    required bool active,
  }) {
    final color = active ? PrivetTheme.signal : PrivetTheme.paper;
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: () => onPicked(value),
      child: SizedBox(
        height: _itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  'Aa',
                  textAlign: TextAlign.center,
                  style: preview == null
                      ? GoogleFonts.ibmPlexSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: color,
                        )
                      : messageFontStyle(
                          preview,
                          const TextStyle(fontSize: 17),
                        ).copyWith(color: color),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              if (active)
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: PrivetTheme.signal,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the highlight-color popup anchored to the global rect of the calling
/// button/bar. Resolves with the picked color (or [Colors.transparent] for
/// "Remove highlight") or null when dismissed.
///
/// Unlike Flutter's built-in `showMenu` — whose flip-above math lets the menu
/// overlap the anchor button and the text below it — this renders as its own
/// top-level [OverlayEntry] (like [showMessageFontPicker]) and is placed above
/// the anchor when it fits on screen, else below, so it never covers the bar
/// or the highlighted selection.
Future<Color?> showMessageHighlightPicker(
  BuildContext context, {
  required Rect anchor,
}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return Future.value(null);
  final overlaySize = MediaQuery.sizeOf(context);
  final completer = Completer<Color?>();
  // Remember who had focus so the composer / selection stays alive after the
  // menu closes (the menu itself grabs focus for Escape handling).
  final previousFocus = FocusManager.instance.primaryFocus;

  late final OverlayEntry entry;
  void close([Color? value]) {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete(value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousFocus?.requestFocus();
    });
  }

  entry = OverlayEntry(
    builder: (_) => _HighlightPickerOverlay(
      anchor: anchor,
      screenSize: overlaySize,
      onPicked: (value) => close(value),
      onDismissed: () => close(),
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _HighlightPickerOverlay extends StatelessWidget {
  const _HighlightPickerOverlay({
    required this.anchor,
    required this.screenSize,
    required this.onPicked,
    required this.onDismissed,
  });

  final Rect anchor;
  final Size screenSize;
  final ValueChanged<Color?> onPicked;
  final VoidCallback onDismissed;

  static const double _menuWidth = 232;
  static const double _itemHeight = 40;

  @override
  Widget build(BuildContext context) {
    final rows = 1 + kHighlightColors.length; // "Remove highlight" + colors
    final menuHeight = _itemHeight * rows + 1; // + divider
    // Keep the menu on-screen: cap its height and scroll on small windows.
    final height = menuHeight < screenSize.height - 16
        ? menuHeight
        : screenSize.height - 16;

    // Prefer above the anchor (the bar floats over the highlighted text, so
    // above is away from the text); flip below when there is no room on top.
    final fitsAbove = anchor.top - 6 - height >= 8.0;
    final top = fitsAbove
        ? anchor.top - 6 - height
        : (anchor.bottom + 6)
            .clamp(8.0, screenSize.height - height - 8.0);
    final left = (anchor.left + anchor.width / 2 - _menuWidth / 2).clamp(
      8.0,
      (screenSize.width - _menuWidth - 8.0).clamp(8.0, screenSize.width),
    );

    return Stack(
      children: [
        // Full-screen tap barrier — anything outside the menu dismisses it.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismissed,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                onDismissed();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Material(
              color: PrivetTheme.panelElevated,
              elevation: 24,
              shadowColor: Colors.black87,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: PrivetTheme.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: _menuWidth,
                height: height,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final c in kHighlightColors)
                              _item(color: c),
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: PrivetTheme.line,
                            ),
                            _item(color: Colors.transparent),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _item({required Color color}) {
    final isRemove = color == Colors.transparent;
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      onTap: () => onPicked(color),
      child: SizedBox(
        height: _itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: PrivetTheme.line, width: 1),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isRemove
                      ? 'Remove highlight'
                      : '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isRemove ? PrivetTheme.paper : PrivetTheme.paper,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
