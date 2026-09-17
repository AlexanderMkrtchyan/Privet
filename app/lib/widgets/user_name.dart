import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// Display name + @handle so similar names are distinguishable.
class UserNameBlock extends StatelessWidget {
  const UserNameBlock({
    super.key,
    required this.displayName,
    required this.handle,
    this.isYou = false,
    this.titleSize = 16,
    this.compact = false,
  });

  final String displayName;
  final String handle;
  final bool isYou;
  final double titleSize;
  final bool compact;

  factory UserNameBlock.fromUser(
    PrivetUser user, {
    bool isYou = false,
    double titleSize = 16,
    bool compact = false,
  }) {
    return UserNameBlock(
      displayName: user.displayName,
      handle: user.handle,
      isYou: isYou,
      titleSize: titleSize,
      compact: compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: PrivetTheme.revision,
      builder: (context, _, _) => _buildName(),
    );
  }

  Widget _buildName() {
    final handleText = handle.isEmpty
        ? ''
        : isYou
            ? '@$handle · you'
            : '@$handle';

    if (compact) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: displayName,
              style: PrivetTheme.titleStyle(
                fontWeight: FontWeight.w700,
                fontSize: titleSize,
                color: PrivetTheme.paper,
              ),
            ),
            if (handleText.isNotEmpty)
              TextSpan(
                text: '  $handleText',
                style: TextStyle(
                  color: PrivetTheme.mist,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          isYou ? '$displayName (you)' : displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: PrivetTheme.titleStyle(
            fontWeight: FontWeight.w700,
            fontSize: titleSize,
          ),
        ),
        if (handleText.isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(
            handleText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: PrivetTheme.signal,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}
