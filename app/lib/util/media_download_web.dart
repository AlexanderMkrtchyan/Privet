// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

/// Downloads without opening a new tab. Fetches as a blob so the `download`
/// attribute works even when the Flutter UI and API are on different ports.
/// The browser owns the actual save, so there is no local path to report.
Future<String?> downloadMedia(String url, {String? filename}) async {
  final name = (filename != null && filename.isNotEmpty)
      ? filename
      : url.split('/').last.split('?').first;

  html.Blob blob;
  try {
    final response = await html.HttpRequest.request(
      url,
      method: 'GET',
      responseType: 'blob',
    );
    final data = response.response;
    if (data is! html.Blob) {
      throw StateError('empty download');
    }
    blob = data;
  } catch (_) {
    // Same-origin fallback if fetch fails.
    final anchor = html.AnchorElement(href: url)
      ..download = name
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    return null;
  }

  final objectUrl = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: objectUrl)
    ..download = name
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(objectUrl);
  return null;
}
