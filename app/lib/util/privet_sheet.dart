import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'low_resource.dart';
import 'ui_overlay_pause.dart';

/// True on native desktop (and wide web windows) where Material bottom-sheet
/// slide animations are heavier than a centered popup.
bool privetPreferDesktopPopups(BuildContext context) {
  if (!kIsWeb) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
        return true;
      default:
        break;
    }
  }
  return MediaQuery.sizeOf(context).width >= PrivetTheme.wideBreakpoint;
}

/// Desktop: centered fade+scale dialog. Phone: Material bottom sheet.
///
/// Keep real motion when the GPU can take it. Only [privetLowResource] (manual
/// opt-in) collapses transitions to instant — never auto-cut animations on a
/// capable machine just because the first boot frames were cold.
Future<T?> showPrivetSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  ShapeBorder? shape,
  double desktopMaxWidth = 480,
  double desktopMaxHeightFraction = 0.88,
}) {
  final bg = backgroundColor ?? PrivetTheme.panel;
  final instant = privetLowResource;

  if (privetPreferDesktopPopups(context)) {
    UiOverlayPause.push();
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: privetAnim(const Duration(milliseconds: 180)),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        if (instant) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
            child: child,
          ),
        );
      },
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final maxH =
            MediaQuery.sizeOf(ctx).height * desktopMaxHeightFraction;
        return SafeArea(
          child: Center(
            child: RepaintBoundary(
              child: Material(
                color: bg,
                elevation: privetElevation(8),
                shadowColor: Colors.black54,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: desktopMaxWidth,
                    maxHeight: maxH,
                    minWidth: 360,
                  ),
                  child: builder(ctx),
                ),
              ),
            ),
          ),
        );
      },
    ).whenComplete(UiOverlayPause.pop);
  }

  UiOverlayPause.push();
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: bg,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    shape: shape,
    sheetAnimationStyle: AnimationStyle(
      duration: privetAnim(const Duration(milliseconds: 200)),
      reverseDuration: privetAnim(const Duration(milliseconds: 160)),
    ),
    builder: builder,
  ).whenComplete(UiOverlayPause.pop);
}
