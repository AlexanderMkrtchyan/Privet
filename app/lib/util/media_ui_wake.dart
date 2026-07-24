import 'media_ui_wake_stub.dart'
    if (dart.library.html) 'media_ui_wake_web.dart' as impl;

/// After getUserMedia / permission dialogs — restore Flutter web input & paint.
void wakeUiAfterMediaDialog() => impl.wakeUiAfterMediaDialog();
