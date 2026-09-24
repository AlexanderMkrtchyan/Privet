import 'video_cache_stub.dart'
    if (dart.library.io) 'video_cache_io.dart' as impl;

/// On-disk cache of chat videos so the next open is a local file (instant
/// seek, no network underruns). Web keeps the browser HTTP cache instead.
Future<void> initVideoCache() => impl.initVideoCache();

/// Absolute path of a complete cached file, or null. Safe from build().
String? videoCachePathSync(String url) => impl.videoCachePathSync(url);

/// Path for [url], downloading if needed. Null when the file is too large
/// or the fetch fails.
Future<String?> videoCacheEnsure(String url) => impl.videoCacheEnsure(url);

/// Write-through after a local upload so the first play uses the file we
/// just sent instead of fetching it again.
Future<void> videoCacheWarmBytes(String url, List<int> bytes) =>
    impl.videoCacheWarmBytes(url, bytes);

/// Start a background download if [url] is not already local and not [hold]ing.
void videoCacheWarm(String url) => impl.videoCacheWarm(url);

/// Block background full-file downloads while the player is streaming [url]
/// so the two GETs do not starve each other through Cloudflare.
void videoCacheHold(String url) => impl.videoCacheHold(url);

/// Allow [videoCacheWarm] again, then prefetch for the next open.
void videoCacheReleaseAndWarm(String url) => impl.videoCacheReleaseAndWarm(url);
