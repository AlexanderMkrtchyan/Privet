import 'page_uri_stub.dart'
    if (dart.library.html) 'page_uri_web.dart' as impl;

/// Current page URI including query/hash.
///
/// Prefer this over [Uri.base] on web: Flutter's `Uri.base` uses
/// `document.baseURI`, which follows `<base href="/">` and **drops** the
/// query string — so `?invite=…` would never be seen.
Uri currentPageUri() => impl.currentPageUri();

/// Safe `http(s)` origin, or null for `file:` / other schemes.
///
/// [Uri.origin] throws on non-http(s) — fatal on Linux/Windows desktop where
/// [Uri.base] is a file path.
String? httpOrigin(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  try {
    final origin = uri.origin;
    return origin.isEmpty ? null : origin;
  } catch (_) {
    return null;
  }
}
