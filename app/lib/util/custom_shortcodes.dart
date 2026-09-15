import 'dart:convert';

/// One user-defined emoticon shortcode (trigger → Unicode emoji).
class CustomShortcode {
  const CustomShortcode({
    required this.trigger,
    required this.emoji,
    this.kolobokFile,
  });

  final String trigger;
  final String emoji;

  /// Pack basename when the user picked a Kolobok (so preview matches exactly).
  final String? kolobokFile;

  bool get isActive => trigger.trim().isNotEmpty && emoji.trim().isNotEmpty;

  CustomShortcode copyWith({
    String? trigger,
    String? emoji,
    String? kolobokFile,
    bool clearKolobokFile = false,
  }) =>
      CustomShortcode(
        trigger: trigger ?? this.trigger,
        emoji: emoji ?? this.emoji,
        kolobokFile:
            clearKolobokFile ? null : (kolobokFile ?? this.kolobokFile),
      );

  Map<String, dynamic> toJson() => {
        'trigger': trigger,
        'emoji': emoji,
        if (kolobokFile != null && kolobokFile!.isNotEmpty)
          'kolobokFile': kolobokFile,
      };

  factory CustomShortcode.fromJson(Map<String, dynamic> json) =>
      CustomShortcode(
        trigger: (json['trigger'] as String?) ?? '',
        emoji: (json['emoji'] as String?) ?? '',
        kolobokFile: json['kolobokFile'] as String?,
      );
}

/// Fixed number of editable slots shown in Settings / emoji panel.
const int kCustomShortcodeSlots = 10;

/// Default empty board — first four triggers pre-filled as examples the user
/// can bind to any emoji (Kolobok or Google) from the picker.
List<CustomShortcode> defaultCustomShortcodes() => List.generate(
      kCustomShortcodeSlots,
      (i) {
        const starters = [':)', ':D', ':(', ':C', ';)', ':P', 'XD', '<3', ':O', ':/'];
        return CustomShortcode(
          trigger: i < starters.length ? starters[i] : '',
          emoji: '',
        );
      },
    );

List<CustomShortcode> decodeCustomShortcodes(String? raw) {
  if (raw == null || raw.isEmpty) return defaultCustomShortcodes();
  try {
    final list = jsonDecode(raw);
    if (list is! List) return defaultCustomShortcodes();
    final out = <CustomShortcode>[];
    for (final item in list) {
      if (item is Map<String, dynamic>) {
        out.add(CustomShortcode.fromJson(item));
      } else if (item is Map) {
        out.add(
          CustomShortcode.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }
    while (out.length < kCustomShortcodeSlots) {
      out.add(const CustomShortcode(trigger: '', emoji: ''));
    }
    return out.take(kCustomShortcodeSlots).toList(growable: false);
  } catch (_) {
    return defaultCustomShortcodes();
  }
}

String encodeCustomShortcodes(List<CustomShortcode> list) =>
    jsonEncode(list.map((e) => e.toJson()).toList());

/// Active (trigger, emoji) pairs, longest trigger first (for expand).
List<(String, String)> activeCustomShortcodePairs(
  List<CustomShortcode> list,
) {
  final pairs = <(String, String)>[
    for (final s in list)
      if (s.isActive) (s.trigger.trim(), s.emoji.trim()),
  ];
  pairs.sort((a, b) => b.$1.length.compareTo(a.$1.length));
  return pairs;
}
