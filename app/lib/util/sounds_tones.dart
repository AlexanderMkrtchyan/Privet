import 'dart:math' as math;
import 'dart:typed_data';

/// Shared PCM tone builders for native (audioplayers) and web (data-URI) playback.

Uint8List silenceWav({required int ms}) {
  const sampleRate = 22050;
  final total = (sampleRate * ms / 1000).round().clamp(1, sampleRate);
  return wrapWav(Int16List(total), sampleRate);
}

Uint8List buildToneWav({
  required List<double> freqs,
  required int pulseMs,
  required int gapMs,
  required int periodMs,
  required int seconds,
}) {
  const sampleRate = 22050;
  final total = sampleRate * seconds;
  final pcm = Int16List(total);
  final twoPi = 2 * math.pi;
  final seg = math.max(1, pulseMs ~/ freqs.length);
  for (var i = 0; i < total; i++) {
    final tMs = (i * 1000) ~/ sampleRate;
    final inPeriod = tMs % periodMs;
    if (inPeriod >= pulseMs) continue;
    final f = freqs[(inPeriod ~/ seg).clamp(0, freqs.length - 1)];
    final env = 0.35 *
        math.sin(math.pi * (inPeriod / pulseMs).clamp(0.0, 1.0));
    final sample =
        (math.sin(twoPi * f * i / sampleRate) * env * 32767).round();
    pcm[i] = sample.clamp(-32767, 32767);
  }
  assert(gapMs >= 0);
  return wrapWav(pcm, sampleRate);
}

Uint8List wrapWav(Int16List pcm, int sampleRate) {
  final dataSize = pcm.length * 2;
  final bytes = ByteData(44 + dataSize);
  void str(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  str(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);
  var o = 44;
  for (final s in pcm) {
    bytes.setInt16(o, s, Endian.little);
    o += 2;
  }
  return bytes.buffer.asUint8List();
}

Uint8List get connectedToneWav => buildToneWav(
      freqs: const [660.0, 880.0],
      pulseMs: 90,
      gapMs: 50,
      periodMs: 220,
      seconds: 1);
