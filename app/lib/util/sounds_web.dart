// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

html.AudioElement? _ringEl;
html.AudioElement? _outEl;
html.AudioElement? _msgEl;
html.AudioElement? _unlockEl;
bool _ringing = false;
bool _outgoing = false;
bool _unlocked = false;
/// Once peers are connected, never restart ring/ringback until the call ends.
bool _tonesSuppressed = false;
bool _msgPrimed = false;
DateTime? _lastMsgPlayAt;
final Set<String> _recentMsgSoundKeys = <String>{};

html.AudioElement _messageAudio() {
  final existing = _msgEl;
  if (existing != null) return existing;
  final a = html.AudioElement()
    ..preload = 'auto'
    ..src = _messageDataUri;
  _msgEl = a;
  return a;
}

html.AudioElement _unlockAudio() {
  final existing = _unlockEl;
  if (existing != null) return existing;
  final a = html.AudioElement()
    ..preload = 'auto'
    ..src = _silentDataUri;
  _unlockEl = a;
  return a;
}

/// Under a user gesture: create + silent-play the message element once so the
/// first real ding is not a cold `play()` on a never-touched MP3 element.
/// Never touches the element while it is already playing (that aborted dings
/// and led to the old double-sound retry path).
void _primeMessageAudioIfIdle() {
  if (_msgPrimed) return;
  final a = _messageAudio();
  if (!a.paused) {
    // A real ding is in flight — treat as already primed.
    _msgPrimed = true;
    return;
  }
  _msgPrimed = true;
  a.volume = 0.001;
  unawaited(a.play().then((_) {
    // Only rewind if we are still in the silent prime (a real ding sets
    // volume to 0.85 before play).
    if (a.volume <= 0.01) {
      a.pause();
      a.currentTime = 0;
      a.volume = 0.85;
    }
  }).catchError((_) {
    _msgPrimed = false;
  }));
}

/// True when another tab already claimed this message ding (same origin).
bool _claimCrossTabSound(String key) {
  try {
    final storage = html.window.localStorage;
    final storageKey = 'privet.msgSound.$key';
    final now = DateTime.now().millisecondsSinceEpoch;
    final prevRaw = storage[storageKey];
    if (prevRaw != null) {
      final prev = int.tryParse(prevRaw);
      if (prev != null && now - prev < 2500) return false;
    }
    storage[storageKey] = '$now';
    // Best-effort cleanup of older keys so localStorage does not grow forever.
    if (_recentMsgSoundKeys.length > 40) {
      _recentMsgSoundKeys.clear();
    }
    return true;
  } catch (_) {
    return true;
  }
}

/// Call from any user gesture so later notify/ring tones are allowed.
void unlockNotificationAudio() {
  try {
    // Warm the message element on gesture. Unlocking only the silent WAV left
    // the first ding as a cold MP3 play (errors swallowed → no sound).
    _primeMessageAudioIfIdle();

    if (_unlocked) return;
    final a = _unlockAudio();
    _unlocked = true;
    a
      ..volume = 0.001
      ..currentTime = 0;
    unawaited(a.play().then((_) {
      a.pause();
      a.currentTime = 0;
    }).catchError((_) {
      _unlocked = false;
    }));
  } catch (_) {}
}

void playMessageSound({String? messageId}) {
  try {
    final now = DateTime.now();
    final last = _lastMsgPlayAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 700)) {
      return;
    }
    final key = (messageId != null && messageId.isNotEmpty)
        ? messageId
        : 't-${now.millisecondsSinceEpoch}';
    if (_recentMsgSoundKeys.contains(key)) return;
    if (!_claimCrossTabSound(key)) return;
    _recentMsgSoundKeys.add(key);
    _lastMsgPlayAt = now;

    final a = _messageAudio();
    try {
      a.pause();
    } catch (_) {}
    a
      ..volume = 0.85
      ..currentTime = 0;
    // Never retry-play on failure — a second play was the double-ding bug.
    // Autoplay unlock happens via unlockNotificationAudio on user gestures.
    unawaited(a.play().catchError((_) {}));
  } catch (_) {}
}

void startIncomingCallSound() {
  if (_tonesSuppressed) return;
  if (_ringing) return;
  _ringing = true;
  stopOutgoingCallSound();
  try {
    _disposeAudio(_ringEl);
    _ringEl = html.AudioElement()
      ..src = _ringtoneDataUri
      ..loop = true
      ..volume = 0.55;
    unawaited(_ringEl!.play().catchError((_) {}));
  } catch (_) {}
}

void stopIncomingCallSound() {
  _ringing = false;
  _disposeAudio(_ringEl);
  _ringEl = null;
}

void playOutgoingCallSound() {
  if (_tonesSuppressed) return;
  if (_outgoing) return;
  _outgoing = true;
  stopIncomingCallSound();
  try {
    _disposeAudio(_outEl);
    _outEl = html.AudioElement()
      ..src = _ringbackDataUri
      ..loop = true
      ..volume = 0.4;
    unawaited(_outEl!.play().catchError((_) {}));
  } catch (_) {}
}

void stopOutgoingCallSound() {
  _outgoing = false;
  _disposeAudio(_outEl);
  _outEl = null;
}

/// Hard-stop every looping call tone (incoming + outgoing).
void stopAllCallSounds() {
  stopIncomingCallSound();
  stopOutgoingCallSound();
}

/// Peers are connected — kill tones and block any restart until [allowCallTones].
void suppressCallTones() {
  _tonesSuppressed = true;
  _ringing = false;
  _outgoing = false;
  _disposeAudio(_ringEl);
  _disposeAudio(_outEl);
  _ringEl = null;
  _outEl = null;
  // Destroy any orphaned looping call tones left in the DOM.
  try {
    for (final node in html.document.querySelectorAll('audio')) {
      if (node is! html.AudioElement) continue;
      final el = node;
      if (identical(el, _msgEl) || identical(el, _unlockEl)) continue;
      if (el.loop ||
          (el.src.isNotEmpty &&
              (el.src.contains('data:audio') || el.src.startsWith('blob:')))) {
        try {
          el.loop = false;
          el.volume = 0;
          el.pause();
          el.currentTime = 0;
          el.src = '';
          el.load();
        } catch (_) {}
      }
    }
  } catch (_) {}
}

void allowCallTones() {
  _tonesSuppressed = false;
}

void playCallConnectedSound() {
  suppressCallTones();
  _playOnce(_connectedDataUri, volume: 0.45);
}

void _disposeAudio(html.AudioElement? el) {
  if (el == null) return;
  try {
    el.loop = false;
    el.pause();
    el.currentTime = 0;
    el.src = '';
    el.load();
  } catch (_) {}
}

void _playOnce(String dataUri, {required double volume}) {
  try {
    final a = html.AudioElement()
      ..src = dataUri
      ..loop = false
      ..volume = volume;
    unawaited(a.play().then((_) {
      // Drop the element once finished so it cannot linger/restart.
      try {
        a.pause();
        a.src = '';
        a.load();
      } catch (_) {}
    }).catchError((_) {}));
  } catch (_) {}
}

// --- Message tone: embedded MP3. Call tones: generated WAV. ---

String get _silentDataUri => _wavDataUri(_silenceWav(ms: 30));

String get _connectedDataUri => _wavDataUri(_buildToneWav(
      freqs: const [660.0, 880.0],
      pulseMs: 90,
      gapMs: 50,
      periodMs: 220,
      seconds: 1));

String get _ringtoneDataUri => _wavDataUri(_buildToneWav(
      freqs: const [480.0, 620.0],
      pulseMs: 380,
      gapMs: 180,
      periodMs: 2000,
      seconds: 2));

String get _ringbackDataUri => _wavDataUri(_buildToneWav(
      freqs: const [400.0, 450.0],
      pulseMs: 900,
      gapMs: 1100,
      periodMs: 2000,
      seconds: 2));

String _wavDataUri(Uint8List bytes) =>
    'data:audio/wav;base64,${base64Encode(bytes)}';

Uint8List _silenceWav({required int ms}) {
  const sampleRate = 22050;
  final total = (sampleRate * ms / 1000).round().clamp(1, sampleRate);
  return _wrapWav(Int16List(total), sampleRate);
}

Uint8List _buildToneWav({
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
  return _wrapWav(pcm, sampleRate);
}

Uint8List _wrapWav(Int16List pcm, int sampleRate) {
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

// ignore: non_constant_identifier_names
String get _messageDataUri =>
    'data:audio/mpeg;base64,${_messageMp3Base64}';

/// Source: assets/sounds/message-notification.mp3
const _messageMp3Base64 =
    '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YDlVYMABwRwLNowwICgbASZQ8wAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZPEHcFECTqMJAAoHACn0MAABQRwJP8wkACgUASiQYwAGVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sURPWHcGsCz3HvCAgJwEm4PYABwOwJOIe0ACgjgSXRjAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUZO+HcEkCTUMPAAwH4Em0PGABALgJIqwsADASgKSU8AAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sURO8HcDQAykJAAAoJgElIPGABQJQFKqeAADgYAKSgkAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sUROYP8EcCScBiAAoAAA0gAAABAAAB/gAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV';
