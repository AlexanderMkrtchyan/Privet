import 'package:flutter/material.dart';

import '../theme.dart';
import '../util/composer_autocomplete.dart';
import '../util/low_resource.dart';

/// Compact typeahead list shown above the message composer.
class ComposerAutocompletePopup extends StatelessWidget {
  const ComposerAutocompletePopup({
    super.key,
    required this.suggestions,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<ComposerSuggestion> suggestions;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return Material(
      color: PrivetTheme.panelElevated,
      elevation: privetElevation(4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: PrivetTheme.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: suggestions.length,
          itemBuilder: (context, index) {
            final s = suggestions[index];
            final selected = index == selectedIndex;
            return InkWell(
              onTap: () => onSelect(index),
              child: ColoredBox(
                color: selected
                    ? PrivetTheme.signal.withValues(alpha: 0.18)
                    : Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      if (s.detail != null && s.detail!.length <= 4) ...[
                        Text(
                          s.detail!,
                          style: const TextStyle(fontSize: 18),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          s.label,
                          style: TextStyle(
                            color: PrivetTheme.paper,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (s.detail != null && s.detail!.length > 4)
                        Flexible(
                          child: Text(
                            s.detail!,
                            style: TextStyle(
                              color: PrivetTheme.mist,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
