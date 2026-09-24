/// No-op video file cache (web / unsupported platforms).
Future<void> initVideoCache() async {}

String? videoCachePathSync(String url) => null;

Future<String?> videoCacheEnsure(String url) async => null;

Future<void> videoCacheWarmBytes(String url, List<int> bytes) async {}

void videoCacheWarm(String url) {}

void videoCacheHold(String url) {}

void videoCacheReleaseAndWarm(String url) {}
