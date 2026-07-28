import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';

import 'sounds_catalog.dart';
import 'sounds_tones.dart';

AudioPlayer? _msgPlayer;
AudioPlayer? _ringPlayer;
AudioPlayer? _outPlayer;
StreamSubscription<void>? _outCompleteSub;
bool _ringing = false;
bool _outgoing = false;
bool _tonesSuppressed = false;
int _outgoingGen = 0;
DateTime? _lastMsgPlayAt;
final Set<String> _recentMsgSoundKeys = <String>{};
final math.Random _rng = math.Random();

const _messageAsset = 'sounds/message-notification.wav';

Future<AudioPlayer> _ensureMessagePlayer() async {
  final existing = _msgPlayer;
  if (existing != null) return existing;
  final p = AudioPlayer();
  await p.setReleaseMode(ReleaseMode.stop);
  await p.setVolume(1.0);
  _msgPlayer = p;
  return p;
}

/// Warm audio under a user gesture so the first ding is not delayed.
void unlockNotificationAudio() {
  unawaited(() async {
    try {
      final p = await _ensureMessagePlayer();
      await p.setVolume(0.001);
      await p.play(AssetSource(_messageAsset));
      await p.stop();
      await p.setVolume(1.0);
    } catch (_) {}
  }());
}

void playMessageSound({String? messageId}) {
  unawaited(() async {
    try {
      final now = DateTime.now();
      final last = _lastMsgPlayAt;
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 700)) {
        return;
      }
      final key = (messageId != null && messageId.isNotEmpty)
          ? messageId
          : 't-${now.millisecondsSinceEpoch}';
      if (_recentMsgSoundKeys.contains(key)) return;
      _recentMsgSoundKeys.add(key);
      if (_recentMsgSoundKeys.length > 40) {
        _recentMsgSoundKeys.clear();
        _recentMsgSoundKeys.add(key);
      }
      _lastMsgPlayAt = now;

      final p = await _ensureMessagePlayer();
      await p.stop();
      await p.setVolume(1.0);
      await p.play(AssetSource(_messageAsset));
    } catch (_) {}
  }());
}

void startIncomingCallSound() {
  if (_tonesSuppressed) return;
  if (_ringing) return;
  _ringing = true;
  stopOutgoingCallSound();
  unawaited(() async {
    try {
      await _disposePlayer(_ringPlayer);
      final p = AudioPlayer();
      await p.setReleaseMode(ReleaseMode.loop);
      await p.setVolume(0.55);
      _ringPlayer = p;
      await p.play(AssetSource(incomingCallAssetWav));
    } catch (_) {
      _ringing = false;
    }
  }());
}

void stopIncomingCallSound() {
  _ringing = false;
  unawaited(_disposePlayer(_ringPlayer));
  _ringPlayer = null;
}

void playOutgoingCallSound() {
  if (_tonesSuppressed) return;
  if (_outgoing) return;
  _outgoing = true;
  stopIncomingCallSound();
  // Always start a fresh random classical track (never the incoming ringtone).
  unawaited(_playRandomOutgoingTrack());
}

Future<void> _playRandomOutgoingTrack() async {
  if (!_outgoing || _tonesSuppressed) return;
  final gen = ++_outgoingGen;
  try {
    await _outCompleteSub?.cancel();
    _outCompleteSub = null;
    await _disposePlayer(_outPlayer);
    _outPlayer = null;

    final asset =
        outgoingCallAssets[_rng.nextInt(outgoingCallAssets.length)];
    final p = AudioPlayer();
    await p.setReleaseMode(ReleaseMode.stop);
    await p.setVolume(0.45);
    _outPlayer = p;
    _outCompleteSub = p.onPlayerComplete.listen((_) {
      unawaited(_onOutgoingTrackFinished(gen));
    });
    await p.play(AssetSource(asset));
    if (!_outgoing || gen != _outgoingGen || _tonesSuppressed) {
      await _disposePlayer(p);
      if (identical(_outPlayer, p)) _outPlayer = null;
    }
  } catch (_) {
    if (_outgoing && gen == _outgoingGen && !_tonesSuppressed) {
      unawaited(_onOutgoingTrackFinished(gen));
    } else {
      _outgoing = false;
    }
  }
}

Future<void> _onOutgoingTrackFinished(int gen) async {
  if (!_outgoing || gen != _outgoingGen || _tonesSuppressed) return;
  await Future<void>.delayed(const Duration(seconds: 1));
  if (!_outgoing || gen != _outgoingGen || _tonesSuppressed) return;
  await _playRandomOutgoingTrack();
}

void stopOutgoingCallSound() {
  _outgoing = false;
  _outgoingGen++;
  unawaited(_outCompleteSub?.cancel());
  _outCompleteSub = null;
  unawaited(_disposePlayer(_outPlayer));
  _outPlayer = null;
}

void stopAllCallSounds() {
  stopIncomingCallSound();
  stopOutgoingCallSound();
}

void suppressCallTones() {
  _tonesSuppressed = true;
  _ringing = false;
  _outgoing = false;
  _outgoingGen++;
  unawaited(_outCompleteSub?.cancel());
  _outCompleteSub = null;
  unawaited(_disposePlayer(_ringPlayer));
  unawaited(_disposePlayer(_outPlayer));
  _ringPlayer = null;
  _outPlayer = null;
}

void allowCallTones() {
  _tonesSuppressed = false;
}

void playCallConnectedSound() {
  suppressCallTones();
  unawaited(() async {
    try {
      final p = AudioPlayer();
      await p.setReleaseMode(ReleaseMode.stop);
      await p.setVolume(0.45);
      await p.play(BytesSource(connectedToneWav, mimeType: 'audio/wav'));
      p.onPlayerComplete.listen((_) {
        unawaited(p.dispose());
      });
    } catch (_) {}
  }());
}

Future<void> _disposePlayer(AudioPlayer? p) async {
  if (p == null) return;
  try {
    await p.stop();
  } catch (_) {}
  try {
    await p.dispose();
  } catch (_) {}
}
