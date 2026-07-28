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
    // volume to 1.0 before play).
    if (a.volume <= 0.01) {
      a.pause();
      a.currentTime = 0;
      a.volume = 1.0;
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
      ..volume = 1.0
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
    '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';
