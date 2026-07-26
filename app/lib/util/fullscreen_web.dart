import 'dart:html' as html;

Future<void> enterFullscreen() async {
  final root = html.document.documentElement;
  if (root == null) return;
  try {
    await root.requestFullscreen();
  } catch (_) {}
}

Future<void> exitFullscreen() async {
  try {
    if (html.document.fullscreenElement != null) {
      html.document.exitFullscreen();
    }
  } catch (_) {}
}

bool isFullscreen() => html.document.fullscreenElement != null;
