// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

import 'sounds_catalog.dart';

html.AudioElement? _ringEl;
html.AudioElement? _outEl;
html.AudioElement? _msgEl;
html.AudioElement? _unlockEl;
StreamSubscription<html.Event>? _outEndedSub;
bool _ringing = false;
bool _outgoing = false;
bool _unlocked = false;
/// Once peers are connected, never restart ring/ringback until the call ends.
bool _tonesSuppressed = false;
bool _msgPrimed = false;
bool _callAudioPrimed = false;
int _outgoingGen = 0;
DateTime? _lastMsgPlayAt;
final Set<String> _recentMsgSoundKeys = <String>{};
final math.Random _rng = math.Random();

/// Absolute URL — Chrome resolves relative asset paths inconsistently after
/// async media prompts; origin-absolute paths stay stable.
String _assetUrl(String assetPath) {
  final origin = html.window.location.origin;
  return '$origin/assets/assets/$assetPath';
}

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

html.AudioElement _ensureToneEl({
  required html.AudioElement? existing,
  required String role,
  required void Function(html.AudioElement) store,
}) {
  if (existing != null) return existing;
  final a = html.AudioElement()
    ..preload = 'auto'
    ..src = _silentDataUri;
  a.setAttribute('data-privet-tone', role);
  store(a);
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

/// Chrome drops transient user activation across `getUserMedia` awaits.
/// Silent-play dedicated incoming/outgoing elements under a gesture so later
/// `play()` on those same elements is allowed.
void _primeCallAudioIfNeeded() {
  if (_callAudioPrimed) return;
  _callAudioPrimed = true;
  try {
    final ring = _ensureToneEl(
      existing: _ringEl,
      role: 'incoming',
      store: (a) => _ringEl = a,
    );
    final out = _ensureToneEl(
      existing: _outEl,
      role: 'outgoing',
      store: (a) => _outEl = a,
    );
    for (final a in [ring, out]) {
      a.volume = 0.001;
      unawaited(a.play().then((_) {
        if (a.volume <= 0.01) {
          a.pause();
          a.currentTime = 0;
        }
      }).catchError((_) {
        _callAudioPrimed = false;
      }));
    }
  } catch (_) {
    _callAudioPrimed = false;
  }
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
    _primeCallAudioIfNeeded();

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
  _killOrphanTones(keep: 'incoming');
  try {
    final el = _ensureToneEl(
      existing: _ringEl,
      role: 'incoming',
      store: (a) => _ringEl = a,
    );
    el
      ..loop = true
      ..volume = 0.55
      ..src = _assetUrl(incomingCallAssetMp3);
    el.load();
    unawaited(el.play().catchError((_) {}));
  } catch (_) {
    _ringing = false;
  }
}

void stopIncomingCallSound() {
  _ringing = false;
  _stopToneEl(_ringEl);
}

void playOutgoingCallSound() {
  if (_tonesSuppressed) return;
  if (_outgoing) return;
  _outgoing = true;
  stopIncomingCallSound();
  _killOrphanTones(keep: 'outgoing');
  _playRandomOutgoingTrack();
}

void _playRandomOutgoingTrack() {
  if (!_outgoing || _tonesSuppressed) return;
  final gen = ++_outgoingGen;
  try {
    unawaited(_outEndedSub?.cancel());
    _outEndedSub = null;

    final asset =
        outgoingCallAssets[_rng.nextInt(outgoingCallAssets.length)];
    final el = _ensureToneEl(
      existing: _outEl,
      role: 'outgoing',
      store: (a) => _outEl = a,
    );
    el
      ..loop = false
      ..preload = 'auto'
      ..volume = 0.45
      ..src = _assetUrl(asset);
    el.load();
    _outEndedSub = el.onEnded.listen((_) {
      _onOutgoingTrackFinished(gen);
    });
    unawaited(el.play().catchError((_) {
      // Autoplay blocked — retry after a beat (gesture may land later).
      _onOutgoingTrackFinished(gen);
    }));
  } catch (_) {
    _onOutgoingTrackFinished(gen);
  }
}

void _onOutgoingTrackFinished(int gen) {
  if (!_outgoing || gen != _outgoingGen || _tonesSuppressed) return;
  unawaited(Future<void>.delayed(const Duration(seconds: 1)).then((_) {
    if (!_outgoing || gen != _outgoingGen || _tonesSuppressed) return;
    _playRandomOutgoingTrack();
  }));
}

void stopOutgoingCallSound() {
  _outgoing = false;
  _outgoingGen++;
  unawaited(_outEndedSub?.cancel());
  _outEndedSub = null;
  _stopToneEl(_outEl);
}

/// Hard-stop every call tone (incoming + outgoing).
void stopAllCallSounds() {
  stopIncomingCallSound();
  stopOutgoingCallSound();
  _killOrphanTones();
}

/// Peers are connected — kill tones and block any restart until [allowCallTones].
void suppressCallTones() {
  _tonesSuppressed = true;
  _ringing = false;
  _outgoing = false;
  _outgoingGen++;
  unawaited(_outEndedSub?.cancel());
  _outEndedSub = null;
  _stopToneEl(_ringEl);
  _stopToneEl(_outEl);
  _killOrphanTones();
}

void allowCallTones() {
  _tonesSuppressed = false;
}

void playCallConnectedSound() {
  suppressCallTones();
  _playOnce(_connectedDataUri, volume: 0.45);
}

void _stopToneEl(html.AudioElement? el) {
  if (el == null) return;
  try {
    el.loop = false;
    el.pause();
    el.currentTime = 0;
    // Keep the element (Chrome autoplay unlock) but silence + unload media.
    el.removeAttribute('src');
    el.src = _silentDataUri;
    el.load();
  } catch (_) {}
}

/// Destroy any leftover call `<audio>` nodes so an old incoming loop cannot
/// keep playing while outgoing classical should be the only tone.
void _killOrphanTones({String? keep}) {
  try {
    for (final node in html.document.querySelectorAll('audio[data-privet-tone]')) {
      if (node is! html.AudioElement) continue;
      final el = node;
      final role = el.getAttribute('data-privet-tone');
      if (keep != null && role == keep) {
        if (identical(el, _ringEl) || identical(el, _outEl)) continue;
      }
      if (identical(el, _ringEl) || identical(el, _outEl)) {
        if (keep != null && role == keep) continue;
      }
      try {
        el.loop = false;
        el.volume = 0;
        el.pause();
        el.removeAttribute('src');
        el.src = '';
        el.load();
        el.remove();
      } catch (_) {}
    }
  } catch (_) {}
}

void _playOnce(String dataUri, {required double volume}) {
  try {
    final a = html.AudioElement()
      ..src = dataUri
      ..loop = false
      ..volume = volume;
    a.setAttribute('data-privet-tone', 'once');
    unawaited(a.play().then((_) {
      try {
        a.pause();
        a.src = '';
        a.load();
        a.remove();
      } catch (_) {}
    }).catchError((_) {}));
  } catch (_) {}
}

// --- Message tone: embedded MP3. Connected chirp: generated WAV. ---

String get _silentDataUri => _wavDataUri(_silenceWav(ms: 30));

String get _connectedDataUri => _wavDataUri(_buildToneWav(
      freqs: const [660.0, 880.0],
      pulseMs: 90,
      gapMs: 50,
      periodMs: 220,
      seconds: 1));

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
