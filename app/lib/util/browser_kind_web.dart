// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

/// Firefox does not support `displaySurface` / tab pickers the way Chromium does.
bool get isFirefoxBrowser {
  final ua = html.window.navigator.userAgent.toLowerCase();
  return ua.contains('firefox') && !ua.contains('seamonkey');
}
