import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Real sound levels for a sent audio file.
///
/// The server decodes the clip with ffmpeg and answers with one normalised RMS
/// value per bar, so the waveform matches what is actually being said. Results
/// are cached per session; failures resolve to `null` and the caller falls back
/// to a neutral bar track instead of inventing a shape.
final _waveformCache = <String, Future<List<double>?>>{};

Future<List<double>?> loadSoundWaveform(String mediaUrl) {
  if (mediaUrl.isEmpty) return Future.value(null);
  return _waveformCache.putIfAbsent(mediaUrl, () => _fetch(mediaUrl));
}

/// Already-resolved bars, if the clip was loaded before (avoids a frame of
/// placeholder bars when a bubble is rebuilt).
List<double>? cachedSoundWaveform(String mediaUrl) {
  final pending = _waveformCache[mediaUrl];
  return pending == null ? null : _lastValue[mediaUrl];
}

final _lastValue = <String, List<double>?>{};

Future<List<double>?> _fetch(String mediaUrl) async {
  try {
    final media = Uri.parse(mediaUrl);
    final endpoint = media.replace(
      path: '/waveform',
      queryParameters: {'u': media.path},
    );
    final res = await http.get(endpoint).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body);
    final raw = body is Map ? body['peaks'] : null;
    if (raw is! List || raw.isEmpty) return null;
    final peaks = <double>[
      for (final value in raw)
        if (value is num) value.toDouble().clamp(0.0, 1.0) else 0.0,
    ];
    if (peaks.isEmpty) return null;
    _lastValue[mediaUrl] = peaks;
    return peaks;
  } catch (_) {
    return null;
  }
}
