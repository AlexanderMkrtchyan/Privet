import 'desktop_call_window_stub.dart'
    if (dart.library.io) 'desktop_call_window_io.dart' as impl;

/// One-shot window raise when an incoming call arrives on Linux / Windows.
abstract final class DesktopCallWindow {
  static bool get isSupported => impl.isDesktopCallWindowSupported;

  /// Bring Privet to the top once, then release always-on-top immediately
  /// so the user can cover it freely with any other app.
  static Future<void> flashForIncomingCall() =>
      impl.flashDesktopWindowForIncomingCall();
}
