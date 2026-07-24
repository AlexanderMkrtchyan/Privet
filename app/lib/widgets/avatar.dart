import 'package:flutter/material.dart';

import '../theme.dart';

class PrivetAvatar extends StatelessWidget {
  const PrivetAvatar({
    super.key,
    required this.name,
    required this.hue,
    this.avatarUrl,
    this.avatarImage,
    this.online = false,
    this.size = 44,
  });

  final String name;
  final int hue;
  final String? avatarUrl;
  /// Local / in-memory photo (e.g. pending upload preview). Wins over [avatarUrl].
  final ImageProvider? avatarImage;
  final bool online;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
    final networkOk = avatarUrl != null && avatarUrl!.isNotEmpty;
    final image = avatarImage ?? (networkOk ? NetworkImage(avatarUrl!) : null);
    final hasPhoto = image != null;
    return Stack(
      children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: HSLColor.fromAHSL(1, hue % 360, 0.35, 0.28).toColor(),
            border: Border.all(color: PrivetTheme.line),
            image: hasPhoto
                ? DecorationImage(
                    image: image,
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: hasPhoto
              ? null
              : Text(
                  letter,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: size * 0.38,
                    color: PrivetTheme.paper,
                  ),
                ),
        ),
        if (online)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: size * 0.28,
              height: size * 0.28,
              decoration: BoxDecoration(
                color: PrivetTheme.signal,
                shape: BoxShape.circle,
                border: Border.all(color: PrivetTheme.ink, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}
