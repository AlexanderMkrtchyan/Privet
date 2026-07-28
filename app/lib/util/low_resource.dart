import 'package:flutter/material.dart';

import 'gpu_capability.dart';

/// Global cheap-mode switch. Set by [PrivetState.setLowResourceMode] (Profile)
/// or a **one-shot** GPU capability probe at bootstrap when the user has never
/// chosen. Capable GPUs (e.g. RTX) keep full motion; software GL / weak boxes
/// get static emoji and zero-duration transitions.
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

/// One-shot GPU check at bootstrap. Never samples frame timings (that falsely
/// stripped motion on fast NVIDIA boxes during font warm-up).
abstract final class LowResourceAutoDetect {
  static Future<bool> shouldEnableCheapMode() async {
    final capable = await hasCapableGpu();
    return !capable;
  }

  static void start({
    required bool preferenceSet,
    required Future<void> Function() enable,
    VoidCallback? onEnabled,
  }) {
    // Kept for API compat; bootstrap awaits [shouldEnableCheapMode] instead.
  }

  static void cancel() {}
}
