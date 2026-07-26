/// Counts open modal sheets/dialogs so the messenger can skip rebuild ticks
/// while a transition is running (Linux/GTK re-rasterizes dirty layers every
/// frame — WS-driven inbox bumps during a fade look like a slideshow).
abstract final class UiOverlayPause {
  static int _depth = 0;
  static final List<void Function()> _onResume = [];

  static bool get active => _depth > 0;

  static void push() => _depth++;

  static void pop() {
    if (_depth > 0) _depth--;
    if (_depth == 0 && _onResume.isNotEmpty) {
      final pending = List<void Function()>.of(_onResume);
      _onResume.clear();
      for (final fn in pending) {
        fn();
      }
    }
  }

  /// Run [fn] now, or once when the last overlay closes.
  static void afterResume(void Function() fn) {
    if (!active) {
      fn();
      return;
    }
    _onResume.add(fn);
  }
}
