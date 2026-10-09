import 'desktop_window_present_stub.dart'
    if (dart.library.io) 'desktop_window_present_io.dart' as impl;

/// Show and focus the desktop window. [activationToken] is a GNOME startup id.
Future<void> raiseDesktopWindow({String? activationToken}) =>
    impl.raiseDesktopWindow(activationToken: activationToken);
