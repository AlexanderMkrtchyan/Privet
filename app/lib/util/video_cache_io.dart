import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const int _maxEntries = 12;
const int _maxEntryBytes = 400 * 1024 * 1024;
const int _maxTotalBytes = 2 * 1024 * 1024 * 1024;

Directory? _cacheDir;
bool _initialized = false;
Future<void> _init = Future.value();

final List<_CacheEntry> _entries = [];
final Map<String, Future<String?>> _inflight = {};
final Set<String> _held = {};

Future<void> _lock = Future.value();
Future<T> _synchronized<T>(Future<T> Function() fn) {
  final result = _lock.then((_) => fn());
  _lock = result.then((_) {}, onError: (_) {});
  return result;
}

Future<void> initVideoCache() {
  if (_initialized) return _init;
  _initialized = true;
  _init = _doInit();
  return _init;
}

Future<void> _doInit() async {
  try {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'video_cache'));
    await dir.create(recursive: true);
    _cacheDir = dir;
    await _synchronized(_loadIndex);
  } catch (_) {}
}

Future<void> _ensureInit() {
  if (_initialized) return _init;
  return Future.value();
}

String? videoCachePathSync(String url) {
  final dir = _cacheDir;
  if (dir == null) return null;
  final entry = _find(url);
  if (entry == null) return null;
  final file = File(p.join(dir.path, entry.file));
  return file.existsSync() ? file.path : null;
}

Future<void> videoCacheWarmBytes(String url, List<int> bytes) async {
  if (url.isEmpty || bytes.isEmpty || bytes.length > _maxEntryBytes) return;
  await _ensureInit();
  final dir = _cacheDir;
  if (dir == null) return;
  final name = _fileNameFor(url);
  final dest = File(p.join(dir.path, name));
  try {
    await dest.writeAsBytes(bytes, flush: true);
    await _synchronized(() async {
      final old = _find(url);
      if (old != null) _entries.remove(old);
      _entries.add(_CacheEntry(url, name, bytes.length));
      await _prune();
      await _saveIndex();
    });
  } catch (_) {}
}

Future<String?> videoCacheEnsure(String url) async {
  await _ensureInit();
  final hit = videoCachePathSync(url);
  if (hit != null) {
    final entry = _find(url);
    if (entry != null) unawaited(_synchronized(() => _touch(entry)));
    return hit;
  }
  return _inflight.putIfAbsent(url, () async {
    try {
      return await _download(url);
    } finally {
      _inflight.remove(url);
    }
  });
}

void videoCacheWarm(String url) {
  if (url.isEmpty) return;
  if (_held.contains(url)) return;
  if (videoCachePathSync(url) != null) return;
  if (_inflight.containsKey(url)) return;
  unawaited(videoCacheEnsure(url));
}

void videoCacheHold(String url) {
  if (url.isEmpty) return;
  _held.add(url);
}

void videoCacheReleaseAndWarm(String url) {
  _held.remove(url);
  videoCacheWarm(url);
}

Future<void> _loadIndex() async {
  final dir = _cacheDir;
  if (dir == null) return;
  _entries.clear();
  final file = File(p.join(dir.path, 'index.json'));
  try {
    if (!await file.exists()) return;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) return;
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final entry = _CacheEntry.fromJson(raw.cast<String, dynamic>());
      if (entry.file.isEmpty) continue;
      _entries.add(entry);
    }
  } catch (_) {}
}

Future<void> _saveIndex() async {
  final dir = _cacheDir;
  if (dir == null) return;
  try {
    await File(p.join(dir.path, 'index.json')).writeAsString(
      jsonEncode([for (final e in _entries) e.toJson()]),
    );
  } catch (_) {}
}

_CacheEntry? _find(String url) {
  for (final entry in _entries) {
    if (entry.url == url) return entry;
  }
  return null;
}

Future<void> _touch(_CacheEntry entry) async {
  _entries.remove(entry);
  _entries.add(entry);
  await _saveIndex();
}

Future<String?> _download(String url) async {
  final dir = _cacheDir;
  if (dir == null) return null;
  final name = _fileNameFor(url);
  final dest = File(p.join(dir.path, name));
  final part = File(p.join(dir.path, '$name.part'));
  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response =
        await client.send(request).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200 && response.statusCode != 206) {
      return null;
    }
    final total = response.contentLength;
    if (total != null && total > _maxEntryBytes) return null;

    final sink = part.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received > _maxEntryBytes) {
          await sink.close();
          try {
            await part.delete();
          } catch (_) {}
          return null;
        }
        sink.add(chunk);
      }
      await sink.close();
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await part.delete();
      } catch (_) {}
      return null;
    }
    if (received == 0) {
      try {
        await part.delete();
      } catch (_) {}
      return null;
    }
    if (await dest.exists()) {
      try {
        await dest.delete();
      } catch (_) {}
    }
    await part.rename(dest.path);
    await _synchronized(() async {
      final old = _find(url);
      if (old != null) _entries.remove(old);
      _entries.add(_CacheEntry(url, name, received));
      await _prune();
      await _saveIndex();
    });
    return dest.path;
  } catch (_) {
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
    return null;
  } finally {
    client.close();
  }
}

Future<void> _prune() async {
  final dir = _cacheDir;
  if (dir == null) return;
  var total = _entries.fold<int>(0, (sum, e) => sum + e.size);
  while ((_entries.length > _maxEntries || total > _maxTotalBytes) &&
      _entries.isNotEmpty) {
    final victim = _entries.removeAt(0);
    total -= victim.size;
    try {
      await File(p.join(dir.path, victim.file)).delete();
    } catch (_) {}
  }
}

String _fileNameFor(String url) {
  final segments = url
      .split('?')
      .first
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  var base = segments.isEmpty ? 'video' : segments.last;
  if (base.length > 64) base = base.substring(base.length - 64);
  final hash = url.hashCode.abs().toRadixString(16);
  return '${base}_$hash.bin';
}

class _CacheEntry {
  _CacheEntry(this.url, this.file, this.size);

  final String url;
  final String file;
  final int size;

  Map<String, dynamic> toJson() => {'url': url, 'file': file, 'size': size};

  static _CacheEntry fromJson(Map<String, dynamic> json) => _CacheEntry(
        json['url'] as String,
        json['file'] as String,
        (json['size'] as num).toInt(),
      );
}
