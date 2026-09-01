import 'dart:typed_data';

import 'media_cache_stub.dart'
    if (dart.library.html) 'media_cache_web.dart'
    if (dart.library.io) 'media_cache_io.dart' as impl;

/// On-device cache for the last [impl.kMediaCacheMaxEntries] media files
/// (images, documents…). Bytes are kept on disk (native) / IndexedDB (web)
/// so opening an already-seen image or file is instant and never re-downloads
/// from the server.
const int kMediaCacheMaxEntries = impl.kMediaCacheMaxEntries;
Future<void> initMediaCache() => impl.initMediaCache();

/// Synchronous in-memory hit — safe to call from build().
Uint8List? mediaCacheLookupSync(String url) => impl.mediaCacheLookupSync(url);

/// Bytes for [url] if they are already local (memory or disk/IndexedDB),
/// null otherwise. Never touches the network.
Future<Uint8List?> mediaCacheGet(String url) => impl.mediaCacheGet(url);

/// Bytes for [url], from the cache if present, otherwise fetched from the
/// server and stored (so the next open is instant).
Future<Uint8List?> mediaCacheGetOrFetch(String url) =>
    impl.mediaCacheGetOrFetch(url);

/// Stores [bytes] for [url] without a network round-trip — used as the
/// write-through target when bytes were fetched for another purpose (e.g. the
/// image-copy warm path).
Future<void> mediaCacheWarmBytes(String url, Uint8List bytes) =>
    impl.mediaCacheWarmBytes(url, bytes);

/// Pins [urls] so the LRU evictor skips them until [mediaCacheUnpin] is called.
/// The warm pass pins the exact set it is about to download so storing
/// newly-downloaded entries never evicts another still-current entry — which
/// would make the same pass re-download it (cache churn on every boot).
void mediaCachePin(Iterable<String> urls) => impl.mediaCachePin(urls);

/// Clears a previous [mediaCachePin] so normal LRU eviction resumes.
void mediaCacheUnpin() => impl.mediaCacheUnpin();

/// Diagnostic hook — web surfaces cache failures on
/// `window.__privetMediaCacheDiag`; other platforms no-op.
void reportMediaCacheError(String where, String detail) =>
    impl.reportMediaCacheError(where, detail);

/// Saves [url]'s bytes locally, preferring cached bytes (instant) over a
/// network fetch. Returns the saved path on native platforms, or null on web
/// where the browser triggers the download itself.
Future<String?> downloadMediaFromCache(String url, {String? filename}) =>
    impl.downloadMediaFromCache(url, filename: filename);
