import 'package:flutter/material.dart';

/// Global cheap-mode switch. Flipped only by [PrivetState.setLowResourceMode]
/// (Profile → Low RAM & CPU). Do not auto-enable from frame timings — first
/// paint / font warm-up on a fast NVIDIA box is not a weak GPU.
///
/// When true the app prefers: zero-duration transitions, no splash ripples,
/// static emoji, tighter image decode caps, flatter elevation (no soft shadows).
/// The root [MaterialApp] also sets [MediaQueryData.disableAnimations] so
/// Material / implicit animations collapse consistently — not just the call
/// sites that remember to use [privetAnim].
bool privetLowResource = false;

/// Fires whenever [privetLowResource] flips so long-lived State objects
/// (typing dots, emoji) can tear down tickers without waiting for a parent
/// rebuild that might be paused behind a modal sheet.
final ValueNotifier<bool> privetLowResourceListenable = ValueNotifier(false);

/// Keep the global + notifier in lockstep. Call from bootstrap / setters only.
void setPrivetLowResource(bool value) {
  if (privetLowResource == value && privetLowResourceListenable.value == value) {
    return;
  }
  privetLowResource = value;
  privetLowResourceListenable.value = value;
}

/// Alias kept for older call sites / tests.
bool get privetLowResourceEmoji => privetLowResource;
set privetLowResourceEmoji(bool value) => setPrivetLowResource(value);

/// Collapse motion to instant when low-resource is on.
Duration privetAnim(Duration normal) =>
    privetLowResource ? Duration.zero : normal;

/// Soft shadow / Material elevation is expensive on CPU rasterizers.
double privetElevation(double normal) => privetLowResource ? 0 : normal;

/// Instant route transitions for every platform (used by [MaterialApp] theme).
class PrivetInstantPageTransitionsBuilder extends PageTransitionsBuilder {
  const PrivetInstantPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

PageTransitionsTheme privetPageTransitionsTheme({required bool lowResource}) {
  if (!lowResource) {
    return const PageTransitionsTheme();
  }
  return const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: PrivetInstantPageTransitionsBuilder(),
      TargetPlatform.iOS: PrivetInstantPageTransitionsBuilder(),
      TargetPlatform.linux: PrivetInstantPageTransitionsBuilder(),
      TargetPlatform.macOS: PrivetInstantPageTransitionsBuilder(),
      TargetPlatform.windows: PrivetInstantPageTransitionsBuilder(),
      TargetPlatform.fuchsia: PrivetInstantPageTransitionsBuilder(),
    },
  );
}

/// Previously auto-enabled low-resource from early frame jank. Removed: cold
/// first-paint on capable GPUs falsely triggered it and stripped animations.
/// [cancel] remains so older call sites / tests stay safe.
abstract final class LowResourceAutoDetect {
  static void start({
    required bool preferenceSet,
    required Future<void> Function() enable,
    VoidCallback? onEnabled,
  }) {
    // Intentionally a no-op — low-resource is manual only.
  }

  static void cancel() {}
}
