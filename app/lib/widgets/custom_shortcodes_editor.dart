import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../util/custom_shortcodes.dart';
import '../util/kolobok_smileys.dart';
import 'compact_emoji_picker.dart';
import 'kolobok_smiley.dart';
import 'privet_emoji.dart';

/// Edit up to [kCustomShortcodeSlots] trigger → emoji bindings.
class CustomShortcodesEditor extends StatefulWidget {
  const CustomShortcodesEditor({
    super.key,
    required this.initial,
    required this.onSave,
  });

  final List<CustomShortcode> initial;
  final ValueChanged<List<CustomShortcode>> onSave;

  @override
  State<CustomShortcodesEditor> createState() => _CustomShortcodesEditorState();
}

class _CustomShortcodesEditorState extends State<CustomShortcodesEditor> {
  late List<TextEditingController> _triggers;
  late List<String> _emojis;
  late List<String?> _kolobokFiles;
  int? _pickingSlot;

  @override
  void initState() {
    super.initState();
    final src = widget.initial.length >= kCustomShortcodeSlots
        ? widget.initial
        : [
            ...widget.initial,
            ...List.generate(
              kCustomShortcodeSlots - widget.initial.length,
              (_) => const CustomShortcode(trigger: '', emoji: ''),
            ),
          ];
    _triggers = List.generate(
      kCustomShortcodeSlots,
      (i) => TextEditingController(text: src[i].trigger),
    );
    _emojis = List.generate(kCustomShortcodeSlots, (i) => src[i].emoji);
    _kolobokFiles =
        List.generate(kCustomShortcodeSlots, (i) => src[i].kolobokFile);
  }

  @override
  void dispose() {
    for (final c in _triggers) {
      c.dispose();
    }
    super.dispose();
  }

  List<CustomShortcode> _snapshot() => List.generate(
        kCustomShortcodeSlots,
        (i) => CustomShortcode(
          trigger: _triggers[i].text.trim(),
          emoji: _emojis[i].trim(),
          kolobokFile: _kolobokFiles[i],
        ),
      );

  void _save() => widget.onSave(_snapshot());

  @override
  Widget build(BuildContext context) {
    // [PrivetTheme.paper] = primary text; [ink] is the app background — never
    // use ink for labels on dark panels.
    final title = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      color: PrivetTheme.paper,
    );
    final body = TextStyle(
      fontSize: 12,
      color: PrivetTheme.mist,
      height: 1.35,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Custom shortcodes', style: title),
        const SizedBox(height: 4),
        Text(
          'Up to $kCustomShortcodeSlots. Type a trigger (e.g. :) or (lol)), '
          'then tap the emoji to pick from Kolobok / Google. Customs override '
          'built-ins with the same trigger.',
          style: body,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < kCustomShortcodeSlots; i++) ...[
          _row(i),
          if (i < kCustomShortcodeSlots - 1) const SizedBox(height: 6),
        ],
        if (_pickingSlot != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CompactEmojiPicker(
              height: 260,
              showDivider: false,
              onSelected: (_) {},
              onPicked: (emoji, {kolobokFile}) {
                final slot = _pickingSlot;
                if (slot == null) return;
                setState(() {
                  _emojis[slot] = emoji;
                  _kolobokFiles[slot] = kolobokFile;
                  _pickingSlot = null;
                });
                _save();
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _preview(int i) {
    final file = _kolobokFiles[i];
    final emoji = _emojis[i];
    if (file != null && file.isNotEmpty) {
      return KolobokSmiley(file, size: 30, animate: false, semanticLabel: emoji);
    }
    if (emoji.isEmpty) {
      return Icon(Icons.add_reaction_outlined, size: 20, color: PrivetTheme.mist);
    }
    // Fall back: map unicode → pack file, else Google glyph.
    final mapped = kolobokFileForEmoji(emoji);
    if (mapped != null) {
      return KolobokSmiley(mapped, size: 30, animate: false, semanticLabel: emoji);
    }
    return PrivetEmoji(emoji, size: 30, animate: false);
  }

  Widget _row(int i) {
    final picking = _pickingSlot == i;
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: TextField(
            controller: _triggers[i],
            style: TextStyle(
              fontSize: 14,
              fontFamily: 'monospace',
              color: PrivetTheme.paper,
            ),
            cursorColor: PrivetTheme.signal,
            inputFormatters: [
              LengthLimitingTextInputFormatter(12),
            ],
            decoration: InputDecoration(
              isDense: true,
              hintText: ':/',
              hintStyle: TextStyle(color: PrivetTheme.mist, fontSize: 13),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 10,
              ),
              filled: true,
              fillColor: PrivetTheme.panelElevated,
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
            onChanged: (_) => _save(),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: picking
              ? PrivetTheme.signal.withValues(alpha: 0.2)
              : PrivetTheme.panelElevated,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            mouseCursor: SystemMouseCursors.click,
            onTap: () {
              setState(() {
                _pickingSlot = picking ? null : i;
              });
            },
            child: SizedBox(
              width: 48,
              height: 40,
              child: Center(child: _preview(i)),
            ),
          ),
        ),
        const SizedBox(width: 4),
        if (_emojis[i].isNotEmpty || _triggers[i].text.isNotEmpty)
          IconButton(
            tooltip: 'Clear',
            mouseCursor: SystemMouseCursors.click,
            onPressed: () {
              setState(() {
                _triggers[i].clear();
                _emojis[i] = '';
                _kolobokFiles[i] = null;
                if (_pickingSlot == i) _pickingSlot = null;
              });
              _save();
            },
            icon: Icon(Icons.close_rounded, size: 18, color: PrivetTheme.mist),
          ),
      ],
    );
  }
}
