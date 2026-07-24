// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

const _kKey = 'privet_app_clipboard';

void persistClipboardText(String text) {
  try {
    html.window.sessionStorage[_kKey] = text;
  } catch (_) {}
}

String? readClipboardText() {
  try {
    final v = html.window.sessionStorage[_kKey];
    if (v != null && v.isNotEmpty) return v;
  } catch (_) {}
  return null;
}
