import 'web_bootstrap_stub.dart'
    if (dart.library.html) 'web_bootstrap_web.dart' as impl;

/// Web-only bootstrap: suppress browser context menu, etc.
void bootstrapWebPlatform() => impl.bootstrapWebPlatform();

/// Blur the active DOM input and resync visualViewport (PWA keyboard gap).
void dismissSoftKeyboard() => impl.dismissSoftKeyboard();
