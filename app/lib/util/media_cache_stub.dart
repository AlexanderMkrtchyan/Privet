import 'dart:typed_data';

/// No-op media cache for unsupported platforms.
const int kMediaCacheMaxEntries = 20;

Future<void> initMediaCache() async {}

Uint8List? mediaCacheLookupSync(String url) => null;

Future<Uint8List?> mediaCacheGet(String url) async => null;

Future<Uint8List?> mediaCacheGetOrFetch(String url) async => null;

Future<void> mediaCacheWarmBytes(String url, Uint8List bytes) async {}

void mediaCachePin(Iterable<String> urls) {}

void mediaCacheUnpin() {}

void reportMediaCacheError(String where, String detail) {}

Future<String?> downloadMediaFromCache(String url, {String? filename}) async =>
    null;
