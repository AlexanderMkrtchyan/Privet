import 'page_uri_stub.dart'
    if (dart.library.html) 'page_uri_web.dart' as impl;

/// Current page URI including query/hash.
///
/// Prefer this over [Uri.base] on web: Flutter's `Uri.base` uses
/// `document.baseURI`, which follows `<base href="/">` and **drops** the
/// query string — so `?invite=…` would never be seen.
Uri currentPageUri() => impl.currentPageUri();
