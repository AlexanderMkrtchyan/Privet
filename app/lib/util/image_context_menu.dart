import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme.dart';
import '../util/copy_image.dart';
import '../util/low_resource.dart';
import '../util/media_download.dart';

/// Result of [showImageContextMenu].
enum ImageContextAction { copy, download }

/// True while a right-click image menu is showing. The message bubble's own
/// secondary-click menu checks this so right-clicking an image does not also
/// open the whole-bubble menu on the same pointer-down.
bool imageContextMenuOpen = false;

/// Shows the image right-click menu at [globalPosition], then performs the
/// chosen action: Download, or Copy image. Used by the lightbox. Success is
/// silent — feedback appears only when copying fails.
Future<void> handleImageContextMenu(
  BuildContext context, {
  required String url,
  required String filename,
  required Offset globalPosition,
}) async {
  if (imageContextMenuOpen) return;
  imageContextMenuOpen = true;
  try {
    // Warm the copy cache while the menu is up so the copy is instant.
    unawaited(prefetchImageForCopy(url));
    final action = await showImageContextMenu(
      context,
      globalPosition: globalPosition,
    );
    if (!context.mounted || action == null) return;
    if (action == ImageContextAction.download) {
      await downloadMedia(url, filename: filename);
      return;
    }
    final ok = await copyImageToClipboard(url, filename: filename);
    if (ok || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Could not copy image — use Download'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  } finally {
    imageContextMenuOpen = false;
  }
}

/// Small right-click menu shown over an image: Copy image / Download.
///
/// Opens in its own dialog route positioned at [globalPosition] (like the
/// message-bubble menu) so it works from both the chat and the lightbox.
/// Returns the chosen [ImageContextAction] or null when dismissed.
Future<ImageContextAction?> showImageContextMenu(
  BuildContext context, {
  required Offset globalPosition,
}) async {
  final size = MediaQuery.sizeOf(context);
  final left = (globalPosition.dx - 8).clamp(8.0, size.width - 208.0);
  final top = (globalPosition.dy - 8).clamp(8.0, size.height - 160.0);

  return showGeneralDialog<ImageContextAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Image actions',
    barrierColor: Colors.transparent,
    transitionDuration: privetAnim(const Duration(milliseconds: 120)),
    pageBuilder: (dialogCtx, anim, secondary) {
      Widget menu = Material(
        color: PrivetTheme.panelElevated,
        elevation: privetElevation(12),
        shadowColor: Colors.black54,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 200,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: PrivetTheme.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ImageMenuItem(
                icon: Icons.copy_rounded,
                label: 'Copy image',
                onTap: () =>
                    Navigator.of(dialogCtx).pop(ImageContextAction.copy),
              ),
              _ImageMenuItem(
                icon: Icons.download_rounded,
                label: 'Download',
                onTap: () =>
                    Navigator.of(dialogCtx).pop(ImageContextAction.download),
              ),
            ],
          ),
        ),
      );
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(dialogCtx).pop(),
              onSecondaryTap: () => Navigator.of(dialogCtx).pop(),
            ),
          ),
          Positioned(left: left, top: top, child: menu),
        ],
      );
    },
  );
}

class _ImageMenuItem extends StatelessWidget {
  const _ImageMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      mouseCursor: SystemMouseCursors.click,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: PrivetTheme.signal.withValues(alpha: 0.95),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: GoogleFonts.ibmPlexSans(
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
