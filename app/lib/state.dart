import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/scheduler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api/client.dart';
import 'api/realtime.dart';
import 'models.dart';
import 'remote_control/control_channel.dart';
import 'remote_control/protocol.dart';
import 'util/ai_turn.dart';
import 'util/display_capture.dart';
import 'util/emoticon_expand.dart';
import 'util/mobile_push.dart';
import 'util/page_title.dart';
import 'util/page_uri.dart';
import 'util/media_ui_wake.dart';
import 'util/remote_input.dart';
import 'util/sounds.dart';
import 'util/throttle.dart';
import 'util/web_notifications.dart';
import 'widgets/privet_emoji.dart';

/// How Privet AI replies are delivered once the user enables AI.
enum AiUsageScope {
  /// # answers stay private (local-only bubbles).
  onlyMe,

  /// # question and answer are posted into the chat for everyone.
  shared,
}

extension AiUsageScopeX on AiUsageScope {
  String get storageValue => name;

  static AiUsageScope fromStorage(String? raw) {
    switch (raw) {
      case 'shared':
        return AiUsageScope.shared;
      // Legacy values from an earlier settings layout.
      case 'direct':
      case 'group':
      case 'onlyMe':
      default:
        return AiUsageScope.onlyMe;
    }
  }

  String get label => switch (this) {
    AiUsageScope.onlyMe => 'Only me',
    AiUsageScope.shared => 'Share with chat',
  };

  String get hint => switch (this) {
    AiUsageScope.onlyMe =>
      'Your # questions and answers stay private — only you see them.',
    AiUsageScope.shared =>
      'Your # question and the AI answer are posted for everyone in the chat.',
  };
}

class CallSession extends ChangeNotifier {
  CallSession({
    required this.rt,
    required this.api,
    required this.selfId,
    required this.call,
    required this.peer,
    required this.isCaller,
    this.preparedDisplay,
    this.preparedLocal,
    this.wantLocalVideo = true,
  });

  final RealtimeClient rt;
  final ApiClient api;
  final String selfId;
  final CallInfo call;
  final PrivetUser peer;
  final bool isCaller;

  /// Screen stream captured during the Share click (Firefox transient activation).
  final MediaStream? preparedDisplay;

  /// Mic/camera stream acquired before accept (avoids hangup-on-Allow race).
  final MediaStream? preparedLocal;

  /// Whether this side intends to send camera (video invites can be answered audio-only).
  final bool wantLocalVideo;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _display;

  /// Kept across stop/replace so we can find the video m-line after track=null.
  RTCRtpSender? _videoSender;

  /// Stable id for the video m-line. On web, [getTransceivers] rewraps every
  /// sender/transceiver in a brand-new Dart object on each call, so neither
  /// `identical(sender, _videoSender)` nor a null `sender.track` (right after
  /// a stop) can relocate it — that silently broke "share again after the
  /// other side stopped". The SDP mid never changes once negotiated, so it's
  /// the only reliable handle across stop/replace/take-over cycles.
  String? _videoMid;

  /// True while our own createOffer/setLocalDescription is in flight — used
  /// to detect offer collisions (perfect negotiation). Without this, both
  /// peers behaved "polite" (always rolled back + accepted the incoming
  /// offer), so a race where both sides renegotiate at once (e.g. the peer
  /// takes over screen share right as we start our own change) left BOTH
  /// sides waiting for an answer to an offer they had already rolled back —
  /// the answer's `setRemoteDescription` then throws in "stable" state and
  /// the connection never finishes renegotiating. That looked exactly like
  /// "the other person can't share after I stop", since sharing again is the
  /// most common way to trigger a same-moment renegotiation on both sides.
  bool _makingOffer = false;

  /// Perfect-negotiation tie-breaker: exactly one side must yield on a
  /// collision. The caller/callee split is already stable and known
  /// identically by both peers, so reuse it instead of inventing new state.
  bool get _polite => !isCaller;
  bool micOn = true;
  bool camOn = true;
  bool sharingScreen = false;

  /// True after this side has shared at least once (detect local stop vs waiting).
  bool everSharedLocally = false;
  bool ready = false;
  bool remoteHasVideo = false;
  Timer? _remoteVideoMuteTimer;

  /// Remote screen/video track ended — clear frozen last frame in the UI.
  bool remoteShareStopped = false;

  /// Peer is actively sending a display surface (one-way screen share).
  bool peerSharingScreen = false;

  /// Peer advertised that their share can accept remote input (native host).
  bool peerShareControllable = false;

  /// Capability metadata from the peer's last `call.share_started`.
  String peerShareControlPlatform = '';
  String peerShareControlBackend = '';
  String peerShareControlDetail = '';
  String? error;

  /// Signaling that arrived before [init] finished (common on screen share).
  Map<String, dynamic>? _pendingOffer;
  Map<String, dynamic>? _pendingAnswer;
  final List<Map<String, dynamic>> _pendingIce = [];
  bool _remoteDescriptionSet = false;

  RemoteControlChannel? remoteControl;

  String get peerId => peer.id;

  bool get remoteControlActive => remoteControl?.state.isGranted == true;
  bool get remoteControlIncomingRequest =>
      remoteControl?.incomingRequest == true;
  bool get canRequestRemoteControl {
    final rc = remoteControl;
    if (rc == null) return false;
    if (!rc.canRequestControl) return false;
    // Only the viewer requests control — never the person already sharing.
    if (sharingScreen) return false;
    if (!peerSharingScreen || remoteShareStopped) return false;
    // Peer must be a native host that can inject OS input.
    return peerShareControllable;
  }

  /// Why the Control button is inactive (for tooltips).
  String? get remoteControlBlockedReason {
    if (remoteControlActive || isRemoteHost) return null;
    if (remoteControl?.state.auth == RemoteControlAuth.requested &&
        remoteControl?.state.role == RemoteControlRole.controller) {
      return null;
    }
    if (sharingScreen) {
      return remoteInputCapability?.canInject == true
          ? 'You are sharing. Wait for the other person to tap Control, then Allow.'
          : 'Stop sharing here. The Ubuntu/Windows app should share, then you tap Control.';
    }
    if (!peerSharingScreen || remoteShareStopped) {
      return 'Wait until the other person shares their screen from the desktop app.';
    }
    if (!peerShareControllable) {
      return remoteControlUnavailableReason(
        peerShareControllable: false,
        peerPlatform: peerShareControlPlatform,
        peerDetail: peerShareControlDetail,
      );
    }
    return null;
  }

  bool get isRemoteController => remoteControl?.state.isController == true;
  bool get isRemoteHost => remoteControl?.state.isHost == true;
  RemoteInputCapability? get remoteInputCapability => remoteControl?.capability;
  String? get remoteControlError => remoteControl?.error;

  bool get hasMicTrack => _local?.getAudioTracks().isNotEmpty == true;
  bool get hasCamTrack => _local?.getVideoTracks().isNotEmpty == true;
  bool get isScreenCall => call.mode == 'screen';

  /// True when this side is the one sending a display surface.
  bool get isSharingLocally => sharingScreen;

  /// Screen call where we stopped sharing (or peer stopped) — not "still connecting".
  /// Video calls never use this placeholder: a peer camera mute/end must not
  /// look like "Screen share stopped".
  ///
  /// Do not treat "I shared earlier" as stopped once the peer is sharing (or
  /// their video is bound). Sticky [everSharedLocally] alone used to hide
  /// remote video after maximize following a share take-over.
  bool get showShareStopped =>
      call.mode == 'screen' &&
      !sharingScreen &&
      !peerSharingScreen &&
      !remoteHasVideo &&
      (remoteShareStopped || everSharedLocally);

  /// Share button: unlocked after peer stop even if a mute/unmute race left
  /// [peerSharingScreen] stuck true (that regression blocked take-over).
  bool get canStartScreenShare => !peerSharingScreen || remoteShareStopped;

  /// Video call where we wanted a camera but have none yet (denied / busy /
  /// answered audio-only). Tapping the camera button calls [retryCamera].
  bool get cameraPending =>
      call.mode == 'video' && !sharingScreen && !hasCamTrack;

  /// Intentionally joined without camera (can still enable later).
  bool get joinedAudioOnly =>
      call.mode == 'video' && !wantLocalVideo && !hasCamTrack;

  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    final ice = await api.iceServers();
    _pc = await createPeerConnection({
      'iceServers': ice.isEmpty
          ? [
              {'urls': 'stun:stun.l.google.com:19302'},
            ]
          : ice,
      'sdpSemantics': 'unified-plan',
    });

    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      rt.sendIce(callId: call.id, toUserId: peerId, candidate: c.toMap());
    };
    _pc!.onTrack = (event) {
      _attachRemoteTrack(event);
    };

    remoteControl = RemoteControlChannel(
      rt: rt,
      callId: call.id,
      selfId: selfId,
      peerId: peerId,
      isCaller: isCaller,
      notify: notifyListeners,
      isSharingLocally: () => sharingScreen,
      peerSharingScreen: () => peerSharingScreen && !remoteShareStopped,
    );
    await remoteControl!.attach(_pc!);

    final isScreen = call.mode == 'screen';
    // Asymmetric: video-mode invite can still join send-audio / recv-video only.
    final withCamera = call.mode == 'video' && wantLocalVideo;

    if (isScreen) {
      // Screen share must work with zero mic/camera hardware.
      // Do NOT call getUserMedia first — on Firefox it can end the display
      // capture stream and/or hang the call when no device exists.
      micOn = false;
      _local = null;

      if (isCaller) {
        late final MediaStream display;
        if (preparedDisplay != null) {
          display = preparedDisplay!;
        } else {
          // Fallback (e.g. mid-call toggle) — may fail on Firefox without a click.
          try {
            display = await captureDisplayMedia();
          } catch (e) {
            throw StateError(
              'Screen share unavailable (start from the Share button click). ($e)',
            );
          }
        }
        await stripDisplayAudioTracks(display);
        final videoTracks = display.getVideoTracks();
        if (videoTracks.isEmpty) {
          throw StateError(
            'Screen capture ended before the call connected. Click Share again.',
          );
        }
        final screenTrack = videoTracks.first;
        screenTrack.enabled = true;

        // Recv-only audio so the peer can still send mic if they have one.
        await _pc!.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
        // Send screen via addTrack — simplest unified-plan path on web.
        _videoSender = await _pc!.addTrack(screenTrack, display);
        _display = display;
        sharingScreen = true;
        everSharedLocally = true;
        // Video-only preview: never attach display audio to the local
        // renderer — tab/system capture can loop ringback through its
        // HTMLAudioElement after accept.
        final preview = await createLocalMediaStream('screen-preview');
        await preview.addTrack(screenTrack);
        localRenderer.srcObject = preview;
        try {
          localRenderer.muted = true;
        } catch (_) {}
        _scheduleRendererRebind();
        screenTrack.onEnded = () {
          _stopScreenShare();
        };
        await _announceShareStarted();
        final settings = screenTrack.getSettings();
        final gw = (settings['width'] as num?)?.toInt();
        final gh = (settings['height'] as num?)?.toInt();
        if (gw != null && gh != null) {
          await remoteControl?.updateLocalGeometry(gw, gh);
        }
      } else {
        // Callee: no local media required. Offer creates recv video m-line.
        localRenderer.srcObject = null;
      }
    } else {
      // Prefer stream acquired during Accept (before signaling) so the
      // permission dialog cannot race a half-started call into hangup.
      if (preparedLocal != null) {
        _local = preparedLocal;
      } else {
        _local = await _acquireUserMedia(withCamera: withCamera);
      }
      // Keep tracks live — some browsers leave them disabled after Allow.
      for (final track in _local!.getTracks()) {
        track.enabled = true;
      }
      // Reflect what we actually got, not what the call mode asked for —
      // camera may have failed (denied/not found/busy) while mic succeeded.
      camOn = withCamera && _local!.getVideoTracks().isNotEmpty;
      localRenderer.srcObject = _local;
      // Local preview must be muted or autoplay is blocked (black / frozen).
      try {
        localRenderer.muted = true;
      } catch (_) {}
      for (final track in _local!.getTracks()) {
        final sender = await _pc!.addTrack(track, _local!);
        if (track.kind == 'video') _videoSender = sender;
      }
      // Audio-only on a video invite: still open a recv-only video m-line so
      // the peer's camera can arrive without requiring us to send one.
      // Only the caller adds it here — the callee attaches to the offer's
      // video m-line in setRemoteDescription (pre-adding would duplicate).
      if (call.mode == 'video' && !hasCamTrack && isCaller) {
        await _pc!.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
    }

    ready = true;
    notifyListeners();

    // Apply any offer/answer/ICE that arrived while getUserMedia / picker ran.
    await _flushPendingSignaling();

    if (isCaller) {
      await _sendOffer();
    }
  }

  /// Soft constraints + retries — strict facingMode/resolution often throws
  /// after the browser permission dialog even when the user clicked Allow
  /// (especially right after a permission-probe getUserMedia that stopped tracks).
  Future<MediaStream> _acquireUserMedia({required bool withCamera}) async {
    final attempts = <Map<String, dynamic>>[
      {'audio': true, 'video': withCamera},
      if (withCamera)
        {
          'audio': true,
          'video': {'facingMode': 'user'},
        },
      if (withCamera) {'audio': true, 'video': true},
    ];
    Object? lastError;
    for (var i = 0; i < attempts.length; i++) {
      try {
        if (i > 0) {
          await Future<void>.delayed(Duration(milliseconds: 180 * i));
        }
        return await navigator.mediaDevices.getUserMedia(attempts[i]);
      } catch (e) {
        lastError = e;
      }
    }
    if (withCamera) {
      // A single physical webcam can only be held by one app/browser at a
      // time (Linux V4L2 exclusivity) — try any other listed camera first.
      final alt = await _tryAlternateCamera();
      if (alt != null) return alt;
      // Still busy — join with audio only rather than failing the call.
      // The camera can be retried later from the call screen.
      try {
        return await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
      } catch (_) {}
    }
    throw lastError ?? StateError('Could not open microphone/camera');
  }

  /// Try every other listed camera device — the default one may be held
  /// exclusively by another app or browser tab.
  Future<MediaStream?> _tryAlternateCamera({bool audio = true}) async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final cams = devices.where((d) => d.kind == 'videoinput').toList();
      for (final cam in cams) {
        if (cam.deviceId.isEmpty) continue;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return await navigator.mediaDevices.getUserMedia({
            'audio': audio,
            'video': {'deviceId': cam.deviceId},
          });
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  Future<void> _flushPendingSignaling() async {
    final offer = _pendingOffer;
    _pendingOffer = null;
    if (offer != null) {
      await handleRemoteOffer(offer);
    }
    final answer = _pendingAnswer;
    _pendingAnswer = null;
    if (answer != null) {
      await handleRemoteAnswer(answer);
    }
    await _flushPendingIce();
  }

  Future<void> _flushPendingIce() async {
    if (!_remoteDescriptionSet || _pc == null) return;
    final ice = List<Map<String, dynamic>>.from(_pendingIce);
    _pendingIce.clear();
    for (final c in ice) {
      await _addIceCandidate(c);
    }
  }

  /// Browsers often fire onTrack with an empty [streams] list under unified-plan.
  Future<void> _attachRemoteTrack(RTCTrackEvent event) async {
    try {
      event.track.enabled = true;

      MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
      } else {
        stream = await createLocalMediaStream('remote-${event.track.id}');
        await stream.addTrack(event.track);
      }

      if (event.track.kind == 'video') {
        await _bindRemoteVideoStream(event.track, stream);
        return;
      }

      if (event.track.kind == 'audio') {
        final current = remoteRenderer.srcObject;
        if (current != null) {
          final already = current.getAudioTracks().any(
            (t) => t.id == event.track.id,
          );
          if (!already) {
            await current.addTrack(event.track);
          }
        } else {
          remoteRenderer.srcObject = stream;
        }
        notifyListeners();
      }
    } catch (e) {
      error = 'Remote media error: $e';
      notifyListeners();
    }
  }

  /// Attach an incoming remote video [track] (wrapped in [stream]) to the
  /// renderer and wire up its mute/unmute/ended handlers. Shared by [onTrack]
  /// and the renegotiation safety net [_bindReceivingVideoTracks].
  Future<void> _bindRemoteVideoStream(
    MediaStreamTrack track,
    MediaStream stream,
  ) async {
    _remoteVideoMuteTimer?.cancel();
    track.enabled = true;
    // Muted leftover after peer stop must not resurrect the presenter lock
    // or wipe [remoteShareStopped] — that blocked the other person sharing.
    final staleMuted = track.muted == true && remoteShareStopped;
    if (!staleMuted) {
      final current = remoteRenderer.srcObject;
      if (current != null) {
        for (final audio in current.getAudioTracks()) {
          final already = stream.getAudioTracks().any((t) => t.id == audio.id);
          if (!already) {
            await stream.addTrack(audio);
          }
        }
      }
      remoteRenderer.srcObject = stream;
      remoteHasVideo = true;
      // Only dedicated screen calls treat any remote video as "peer sharing".
      // Mid-call share on video/audio is gated by call.share_started — marking
      // every camera track as a share locked the receiver's Share button.
      if (call.mode == 'screen') {
        remoteShareStopped = false;
        if (!sharingScreen) {
          peerSharingScreen = true;
        }
      } else if (peerSharingScreen) {
        remoteShareStopped = false;
      }
    }
    // Remember the video m-line so we can flip recv→send when taking over.
    if (_videoSender == null && _pc != null) {
      try {
        final list = await _pc!.getTransceivers();
        for (final t in list) {
          if (t.stoped) continue;
          if (t.receiver.track?.id == track.id) {
            _videoSender = t.sender;
            // Cache the mid now, while the receiver track still makes it
            // unambiguous — this is what lets us take over/reclaim the
            // m-line later even after both sides have gone quiet.
            try {
              _videoMid = t.mid;
            } catch (_) {}
            break;
          }
        }
      } catch (_) {}
    }
    track.onEnded = () {
      _remoteVideoMuteTimer?.cancel();
      _onRemoteVideoEnded(track);
    };
    // replaceTrack commonly emits a short mute while switching camera→screen.
    // Treat only a sustained mute as ended; otherwise clearing srcObject here
    // leaves mobile/PWA renderers permanently white.
    track.onMute = () {
      if (call.mode == 'screen' || peerSharingScreen) {
        _remoteVideoMuteTimer?.cancel();
        _remoteVideoMuteTimer = Timer(const Duration(milliseconds: 900), () {
          if (track.muted == true && !remoteShareStopped) {
            _onRemoteVideoEnded(track);
          }
        });
      }
    };
    track.onUnMute = () {
      _remoteVideoMuteTimer?.cancel();
      // Ignore unmute after an explicit share_stopped / local clear.
      if (remoteShareStopped) return;
      remoteHasVideo = true;
      _scheduleRendererRebind();
      notifyListeners();
    };
    notifyListeners();
  }

  /// Safety net for the screen-share handoff. When the callee takes over
  /// sharing back to the original caller, the caller reuses its old
  /// (previously send-only) transceiver and merely flips it to receiving.
  /// Some engines (notably Chrome via the web wrapper) do NOT re-fire
  /// [onTrack] for that direction change, so the caller would bind nothing and
  /// the peer's new share never appears — exactly the "A can't see B's screen
  /// after B takes over" bug. After every renegotiation, scan the receiving
  /// video transceivers and surface any incoming track [onTrack] missed.
  Future<void> _bindReceivingVideoTracks() async {
    if (_pc == null) return;
    var bound = false;
    try {
      final list = await _pc!.getTransceivers();
      for (final t in list) {
        if (t.stoped) continue;
        TransceiverDirection? dir;
        try {
          dir = await t.getCurrentDirection();
        } catch (_) {}
        final receiving =
            dir == TransceiverDirection.RecvOnly ||
            dir == TransceiverDirection.SendRecv;
        if (!receiving) continue;
        final track = t.receiver.track;
        if (track == null || track.kind != 'video') continue;
        final current = remoteRenderer.srcObject;
        final already =
            current != null &&
            current.getVideoTracks().any((v) => v.id == track.id);
        if (already) continue;
        // Never resurrect a share the peer explicitly stopped.
        if (remoteShareStopped && track.muted == true) continue;
        final wrapper = await createLocalMediaStream('recv-${track.id}');
        await wrapper.addTrack(track);
        await _bindRemoteVideoStream(track, wrapper);
        bound = true;
      }
    } catch (_) {}
    if (bound) {
      // Web reuses one <video> element per renderer; a fresh bind can leave a
      // frozen frame until srcObject is rebound after the frame is laid out.
      SchedulerBinding.instance.addPostFrameCallback((_) => rebindRenderers());
    }
  }

  Future<void> handleRemoteOffer(Map<String, dynamic> sdp) async {
    if (!ready || _pc == null) {
      _pendingOffer = sdp;
      return;
    }
    try {
      // Perfect negotiation: a collision is us mid-offer (or already having
      // sent one) while the peer's offer lands at the same time — e.g. peer
      // takes over screen share right as we start our own track change.
      // Only ONE side may yield or both offers die and their answers throw
      // on an already-stable connection (that's what silently broke "share
      // again after the peer stops" whenever both sides raced). The
      // caller/callee split is a stable, mutually-known tie-breaker: the
      // callee is polite (rolls back + accepts), the caller is impolite
      // (ignores the colliding offer and keeps its own in flight).
      final collision =
          _makingOffer ||
          _pc!.signalingState != RTCSignalingState.RTCSignalingStateStable;
      if (collision && !_polite) {
        // Impolite: drop the peer's offer. Our own offer will get answered
        // once the peer (polite) receives it and yields.
        return;
      }
      if (collision) {
        try {
          await _pc!.setLocalDescription(RTCSessionDescription('', 'rollback'));
        } catch (_) {
          // Some browsers (e.g. older Firefox) lack rollback — fall through.
        }
      }
      await _pc!.setRemoteDescription(
        RTCSessionDescription(sdp['sdp'] as String, sdp['type'] as String),
      );
      _remoteDescriptionSet = true;
      await _flushPendingIce();
      // Don't rely on the browser's implicit "no local track → recvonly"
      // default for the auto-created video transceiver — some engines still
      // answer sendrecv, which would light up our camera on an audio-only
      // answer to a video invite. Force recvonly explicitly whenever we
      // don't intend to send our own camera.
      if (call.mode == 'video' && !wantLocalVideo) {
        final videoT = await _videoTransceiver();
        if (videoT != null) {
          try {
            await videoT.setDirection(TransceiverDirection.RecvOnly);
          } catch (_) {}
        }
      }
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      rt.sendAnswer(callId: call.id, toUserId: peerId, sdp: answer.toMap());
      // onTrack may not re-fire when a reused m-line flips to receiving
      // (screen-share take-over) — bind any incoming video it missed.
      await _bindReceivingVideoTracks();
      _scheduleRendererRebind();
      // We rolled back our own offer above — whatever local track/direction
      // change it was carrying (e.g. our own take-over) is still applied to
      // the senders but was never actually sent to the peer. Re-offer now
      // that we're back in "stable" so it isn't silently dropped.
      if (collision) {
        await _sendOffer();
      }
    } catch (e) {
      error = 'Call renegotiation failed: $e';
      notifyListeners();
    }
  }

  Future<void> handleRemoteAnswer(Map<String, dynamic> sdp) async {
    if (!ready || _pc == null) {
      _pendingAnswer = sdp;
      return;
    }
    // Guard against a stale answer for an offer we already rolled back
    // (should no longer happen with the polite/impolite split above, but a
    // thrown, uncaught setRemoteDescription here previously could leave
    // the connection unable to renegotiate again).
    if (_pc!.signalingState !=
        RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      return;
    }
    try {
      await _pc!.setRemoteDescription(
        RTCSessionDescription(sdp['sdp'] as String, sdp['type'] as String),
      );
      _remoteDescriptionSet = true;
      await _flushPendingIce();
      // Answer to our take-over offer applied — make sure a video track the
      // peer started sending on a reused m-line actually gets bound/rendered.
      await _bindReceivingVideoTracks();
      _scheduleRendererRebind();
    } catch (e) {
      error = 'Call renegotiation failed: $e';
      notifyListeners();
    }
  }

  Future<void> handleIce(Map<String, dynamic> candidate) async {
    // Wait until setRemoteDescription — early ICE was previously dropped.
    if (!ready || _pc == null || !_remoteDescriptionSet) {
      _pendingIce.add(candidate);
      return;
    }
    await _addIceCandidate(candidate);
  }

  Future<void> _addIceCandidate(Map<String, dynamic> candidate) async {
    try {
      await _pc?.addCandidate(
        RTCIceCandidate(
          candidate['candidate'] as String?,
          candidate['sdpMid'] as String?,
          (candidate['sdpMLineIndex'] as num?)?.toInt(),
        ),
      );
    } catch (_) {}
  }

  Future<void> toggleMic() async {
    if (!hasMicTrack) return;
    micOn = !micOn;
    for (final t in _local?.getAudioTracks() ?? []) {
      t.enabled = micOn;
    }
    notifyListeners();
  }

  Future<void> toggleCam() async {
    if (!hasCamTrack || sharingScreen || call.mode == 'screen') return;
    camOn = !camOn;
    for (final t in _local?.getVideoTracks() ?? []) {
      t.enabled = camOn;
    }
    notifyListeners();
  }

  /// Re-attempt to open the camera (e.g. once another app/browser tab
  /// releases it) and add it to the running call without restarting anything.
  Future<void> retryCamera() async {
    if (!cameraPending || _pc == null) return;
    MediaStream? cam;
    try {
      cam = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': true,
      });
    } catch (_) {
      cam = await _tryAlternateCamera(audio: false);
    }
    if (cam == null || cam.getVideoTracks().isEmpty) {
      error =
          'Camera still unavailable — it may be open in another app or browser tab.';
      notifyListeners();
      return;
    }
    final track = cam.getVideoTracks().first;
    track.enabled = true;
    _local ??= await createLocalMediaStream('local');
    await _local!.addTrack(track);
    localRenderer.srcObject = _local;
    try {
      localRenderer.muted = true;
    } catch (_) {}

    final transceiver = await _videoTransceiver();
    if (transceiver != null) {
      try {
        await transceiver.setDirection(TransceiverDirection.SendRecv);
      } catch (_) {}
      try {
        await transceiver.sender.replaceTrack(track);
        _videoSender = transceiver.sender;
      } catch (_) {
        _videoSender = await _pc!.addTrack(track, _local!);
        _videoMid = null;
      }
    } else {
      _videoSender = await _pc!.addTrack(track, _local!);
      _videoMid = null;
    }
    camOn = true;
    error = null;
    notifyListeners();
    await _renegotiateAfterTrackChange();
  }

  Future<void> _renegotiateAfterTrackChange() async {
    await _sendOffer();
  }

  /// Every outgoing offer goes through here so [_makingOffer] always brackets
  /// the create/setLocalDescription pair — that's what lets [handleRemoteOffer]
  /// detect a same-moment offer coming from the peer (see [_makingOffer] doc).
  Future<void> _sendOffer() async {
    if (_pc == null) return;
    _makingOffer = true;
    try {
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      rt.sendOffer(callId: call.id, toUserId: peerId, sdp: offer.toMap());
    } finally {
      _makingOffer = false;
    }
  }

  Future<RTCRtpTransceiver?> _videoTransceiver() async {
    if (_pc == null) return null;
    final list = await _pc!.getTransceivers();

    // Stable path: the SDP mid never changes once negotiated. On web every
    // getTransceivers() call rewraps the sender/transceiver in a brand-new
    // Dart object, so identity checks always miss, and the id-based fallback
    // below is useless once the track has been replaced with null (exactly
    // the state right after a stop) — that combo silently broke "share again
    // after the other side stopped" because the mid-line could no longer be
    // relocated at all. Once we've found it once below, cache the mid so
    // every later stop/replace/take-over is a simple, reliable lookup.
    if (_videoMid != null) {
      for (final t in list) {
        if (t.stoped) continue;
        try {
          if (t.mid == _videoMid) return t;
        } catch (_) {}
      }
    }

    RTCRtpTransceiver? found;
    // Prefer the sender we already used for screen/camera.
    if (_videoSender != null) {
      for (final t in list) {
        if (t.stoped) continue;
        try {
          if (identical(t.sender, _videoSender)) {
            found = t;
            break;
          }
        } catch (_) {}
      }
      // Web wrappers may not be identical — match by current track id if any.
      if (found == null) {
        final id = _videoSender!.track?.id;
        if (id != null) {
          for (final t in list) {
            if (t.stoped) continue;
            if (t.sender.track?.id == id) {
              found = t;
              break;
            }
          }
        }
      }
    }
    if (found == null) {
      for (final t in list) {
        if (t.stoped) continue;
        if (t.sender.track?.kind == 'video' ||
            t.receiver.track?.kind == 'video') {
          found = t;
          break;
        }
      }
    }
    if (found == null) {
      for (final t in list) {
        if (t.stoped) continue;
        try {
          final codecs = t.sender.parameters.codecs;
          if (codecs?.any((c) => (c.kind ?? '') == 'video') == true) {
            found = t;
            break;
          }
        } catch (_) {}
      }
    }
    if (found != null) {
      try {
        _videoMid = found.mid;
      } catch (_) {}
    }
    return found;
  }

  Future<void> toggleScreenShare() async {
    if (sharingScreen) {
      await _stopScreenShare();
      return;
    }
    if (peerSharingScreen && !remoteShareStopped) {
      error = 'Wait for the other person to stop sharing first';
      notifyListeners();
      return;
    }
    // Prefer [startScreenShare] from UI (Privet picker keeps Firefox activation).
    try {
      final display = await captureDisplayMedia();
      await startScreenShare(display);
    } catch (e) {
      error = 'Screen share failed: $e';
      notifyListeners();
    }
  }

  /// Attach a display stream captured under a user gesture (share picker).
  Future<void> startScreenShare(MediaStream display) async {
    MediaStreamTrack? previousVideoTrack;
    var shareAnnounced = false;
    try {
      if (sharingScreen) {
        await _stopScreenShare();
      }
      if (peerSharingScreen && !remoteShareStopped) {
        error = 'Wait for the other person to stop sharing first';
        for (final t in display.getTracks()) {
          await t.stop();
        }
        await display.dispose();
        notifyListeners();
        return;
      }
      // Taking over after peer stop — clear the lock locally immediately.
      peerSharingScreen = false;
      remoteShareStopped = false;

      await stripDisplayAudioTracks(display);
      final tracks = display.getVideoTracks();
      if (tracks.isEmpty) {
        throw StateError('No screen video track.');
      }
      final screenTrack = tracks.first;

      // Reuse the existing video m-line when possible (recv-only after peer
      // stopped). Always renegotiate so the peer starts receiving our share.
      final transceiver = await _videoTransceiver();
      if (transceiver != null) {
        previousVideoTrack = transceiver.sender.track;
        try {
          await transceiver.setDirection(TransceiverDirection.SendRecv);
        } catch (_) {
          try {
            await transceiver.setDirection(TransceiverDirection.SendOnly);
          } catch (_) {}
        }
        try {
          await transceiver.sender.replaceTrack(screenTrack);
          _videoSender = transceiver.sender;
        } catch (_) {
          _videoSender = await _pc!.addTrack(screenTrack, display);
          _videoMid = null; // New transceiver — forget the old mid.
        }
      } else if (_videoSender != null) {
        previousVideoTrack = _videoSender!.track;
        try {
          await _videoSender!.replaceTrack(screenTrack);
        } catch (_) {
          _videoSender = await _pc!.addTrack(screenTrack, display);
          _videoMid = null;
        }
      } else {
        _videoSender = await _pc!.addTrack(screenTrack, display);
        _videoMid = null;
      }
      _display = display;
      sharingScreen = true;
      everSharedLocally = true;
      final preview = await createLocalMediaStream('screen-preview');
      await preview.addTrack(screenTrack);
      localRenderer.srcObject = preview;
      try {
        localRenderer.muted = true;
      } catch (_) {}
      _scheduleRendererRebind();
      screenTrack.onEnded = () {
        _stopScreenShare();
      };
      // Signal first so the peer unlocks / shows "peer sharing", then SDP.
      await _announceShareStarted();
      shareAnnounced = true;
      // Best-effort geometry for control mapping (host).
      final settings = screenTrack.getSettings();
      final gw = (settings['width'] as num?)?.toInt();
      final gh = (settings['height'] as num?)?.toInt();
      if (gw != null && gh != null) {
        await remoteControl?.updateLocalGeometry(gw, gh);
      }
      await _renegotiateAfterTrackChange();
      _scheduleRendererRebind();
      notifyListeners();
    } catch (e) {
      error = 'Screen share failed: $e';
      if (shareAnnounced) {
        rt.sendShareStopped(callId: call.id, toUserId: peerId);
      }
      try {
        final transceiver = await _videoTransceiver();
        if (transceiver != null) {
          await transceiver.sender.replaceTrack(previousVideoTrack);
          _videoSender = transceiver.sender;
        } else {
          await _videoSender?.replaceTrack(previousVideoTrack);
        }
      } catch (_) {}
      _display = null;
      sharingScreen = false;
      if (call.mode == 'screen') {
        remoteShareStopped = true;
      }
      localRenderer.srcObject = _local;
      _scheduleRendererRebind();
      for (final t in display.getTracks()) {
        await t.stop();
      }
      try {
        await display.dispose();
      } catch (_) {}
      await stopDisplayCaptureService();
      notifyListeners();
    }
  }

  void _onRemoteVideoEnded(MediaStreamTrack track) {
    // Drop the renderer stream so the UI cannot keep painting a frozen frame.
    final current = remoteRenderer.srcObject;
    if (current != null) {
      final stillLiveVideo = current.getVideoTracks().any(
        (t) => t.id != track.id && t.enabled && t.muted != true,
      );
      if (!stillLiveVideo) {
        remoteRenderer.srcObject = null;
        remoteHasVideo = false;
        // Only clear the share lock when this really was a screen share —
        // a peer turning their camera off must not flip the video UI into
        // "Screen share stopped" or unlock/lock share incorrectly.
        if (call.mode == 'screen' || peerSharingScreen) {
          remoteShareStopped = true;
          peerSharingScreen = false;
          _clearPeerShareControlMeta();
          unawaited(remoteControl?.onRemoteShareStopped());
        }
        notifyListeners();
      }
    } else {
      remoteHasVideo = false;
      if (call.mode == 'screen' || peerSharingScreen) {
        remoteShareStopped = true;
        peerSharingScreen = false;
        _clearPeerShareControlMeta();
        unawaited(remoteControl?.onRemoteShareStopped());
      }
      notifyListeners();
    }
  }

  void clearRemoteShare() {
    _remoteVideoMuteTimer?.cancel();
    remoteRenderer.srcObject = null;
    remoteHasVideo = false;
    remoteShareStopped = true;
    peerSharingScreen = false;
    _clearPeerShareControlMeta();
    unawaited(remoteControl?.onRemoteShareStopped());
    notifyListeners();
  }

  void _clearPeerShareControlMeta() {
    peerShareControllable = false;
    peerShareControlPlatform = '';
    peerShareControlBackend = '';
    peerShareControlDetail = '';
  }

  Future<void> _announceShareStarted() async {
    final cap = await remoteControl?.refreshCapability();
    rt.sendShareStarted(
      callId: call.id,
      toUserId: peerId,
      controllable: cap?.canInject == true,
      controlPlatform: cap?.platform ?? '',
      controlBackend: cap?.backend ?? '',
      controlDetail: cap?.detail ?? '',
    );
  }

  Future<void> _stopScreenShare() async {
    if (!sharingScreen) return;
    // Explicit signal — browsers often leave a frozen last frame when the
    // track is merely stopped/replaced, without firing mute/ended to the peer.
    // Do NOT renegotiate here: a stop-offer races the peer's take-over offer
    // (glare) and was breaking "other person can share after stop".
    rt.sendShareStopped(callId: call.id, toUserId: peerId);
    await remoteControl?.onLocalShareStopped();

    final isScreenCall = call.mode == 'screen';
    final camTrack =
        !isScreenCall && _local?.getVideoTracks().isNotEmpty == true
        ? _local!.getVideoTracks().first
        : null;

    // Stop sending frames immediately.
    for (final t in _display?.getVideoTracks() ?? []) {
      t.enabled = false;
    }

    final transceiver = await _videoTransceiver();
    if (transceiver != null) {
      try {
        await transceiver.sender.replaceTrack(camTrack);
        _videoSender = transceiver.sender;
      } catch (_) {}
      // Keep SendRecv with a null track so the peer can replaceTrack/send
      // on the same m-line without fighting a RecvOnly renegotiation.
      if (camTrack == null) {
        try {
          await transceiver.setDirection(TransceiverDirection.SendRecv);
        } catch (_) {}
      }
    } else if (_videoSender != null) {
      try {
        await _videoSender!.replaceTrack(camTrack);
      } catch (_) {}
    } else {
      final senders = await _pc!.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          _videoSender = s;
          try {
            await s.replaceTrack(camTrack);
          } catch (_) {}
          break;
        }
      }
    }
    for (final t in _display?.getTracks() ?? []) {
      await t.stop();
    }
    await _display?.dispose();
    await stopDisplayCaptureService();
    _display = null;
    sharingScreen = false;
    // Local stop on a screen call — treat like share-stopped for our UI, and
    // stay ready for the peer (or us) to start sharing again.
    if (isScreenCall) {
      remoteShareStopped = true;
    }
    localRenderer.srcObject = _local;
    _scheduleRendererRebind();
    notifyListeners();
  }

  /// Re-attach streams after RTCVideoView remounts (minimize/maximize on web).
  /// flutter_webrtc reuses a fixed video element id per renderer — remounts can
  /// leave a stale DOM node and a frozen frame until srcObject is rebound.
  void rebindRenderers() {
    final local = localRenderer.srcObject;
    final remote = remoteRenderer.srcObject;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    if (local != null) {
      localRenderer.srcObject = local;
      try {
        localRenderer.muted = true;
      } catch (_) {}
    }
    if (remote != null) {
      remoteRenderer.srcObject = remote;
    }
    notifyListeners();
  }

  void _scheduleRendererRebind() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      rebindRenderers();
      wakeUiAfterMediaDialog();
    });
  }

  Future<void> requestRemoteControl() async {
    final blocked = remoteControlBlockedReason;
    if (blocked != null) {
      await remoteControl?.rejectRequest(blocked);
      notifyListeners();
      return;
    }
    await remoteControl?.requestControl();
    notifyListeners();
  }

  Future<void> grantRemoteControl() async {
    await remoteControl?.grantControl();
    notifyListeners();
  }

  void denyRemoteControl({String reason = 'Remote control was denied.'}) {
    remoteControl?.denyControl(reason: reason);
    notifyListeners();
  }

  Future<void> revokeRemoteControl() async {
    await remoteControl?.revokeControl();
    notifyListeners();
  }

  Future<void> disposeSession() async {
    _remoteVideoMuteTimer?.cancel();
    await remoteControl?.dispose();
    remoteControl = null;
    await _stopScreenShare();
    final local = _local ?? preparedLocal;
    for (final t in local?.getTracks() ?? []) {
      await t.stop();
    }
    await local?.dispose();
    _local = null;
    await _pc?.close();
    await localRenderer.dispose();
    await remoteRenderer.dispose();
  }
}

class PrivetState extends ChangeNotifier {
  PrivetState() {
    _api = ApiClient();
    _rt = RealtimeClient(url: _api.wsUrl);
    _rt.addHandler(_onEvent);
    _disposeVisibility = onDocumentVisible(_onTabVisible);
    // Install web focus hooks early (no-op on non-web).
    documentHasFocus;
  }

  late final ApiClient _api;
  late final RealtimeClient _rt;
  final _uuid = const Uuid();
  void Function()? _disposeVisibility;
  Timer? _focusedReadTimer;
  Timer? _inboxReconcileTimer;
  SharedPreferences? _prefsCache;
  final _typingThrottle = Throttle(const Duration(seconds: 2));
  String? _lastDraftText;

  /// Scoped UI ticks — listeners rebuild only the regions that care.
  /// [sessionTick]: boot / auth / theme / accent / low-resource.
  /// [shellTick]: active conversation identity (pane structure).
  /// [inboxTick]: conversation list / directory / unread.
  /// [chatTick]: messages / reactions / uploads in the open chat.
  /// [typingTick]: peer typing indicator only.
  /// [callTick]: ringing / active call / mini-call chrome.
  final ValueNotifier<int> sessionTick = ValueNotifier(0);
  final ValueNotifier<int> shellTick = ValueNotifier(0);
  final ValueNotifier<int> inboxTick = ValueNotifier(0);
  final ValueNotifier<int> chatTick = ValueNotifier(0);
  final ValueNotifier<int> typingTick = ValueNotifier(0);
  final ValueNotifier<int> callTick = ValueNotifier(0);

  /// Epoch until first real pointer/keyboard activity (see [noteUserPresence]).
  DateTime _lastUserPresence = DateTime.fromMillisecondsSinceEpoch(0);

  PrivetUser? user;
  List<Conversation> conversations = [];
  List<PrivetUser> directory = [];
  final Map<String, List<ChatMessage>> messagesByChat = {};

  /// Chats whose initial history page has finished loading from the API.
  final Set<String> historyLoaded = {};
  final Set<String> _historyLoading = {};
  final Map<String, bool> hasMoreByChat = {};
  final Set<String> loadingOlder = {};

  /// Realtime messages that arrived before history finished loading.
  final Map<String, List<ChatMessage>> _pendingWsMessages = {};
  static const int messagePageSize = 40;

  /// Read cursor when a chat was opened — used for # summarize unread after mark-read.
  final Map<String, String?> _aiUnreadSince = {};
  final Map<String, List<TaskItem>> tasksByChat = {};
  final Set<String> online = {};
  final Map<String, DateTime> lastSeen = {};
  List<PrivetUser> blocked = [];
  String? activeConversationId;
  String? typingUserId;
  String? error;
  bool booting = true;
  bool busy = false;
  bool uploading = false;

  /// Conversation id whose [ConversationPane] is currently mounted, if any.
  String? _surfaceChatId;

  bool get chatSurfaceMounted =>
      _surfaceChatId != null && _surfaceChatId == activeConversationId;

  Map<String, String>? welcomeCredentials;

  /// Handle from `?invite=` — join via invitation link.
  String? pendingInviteHandle;

  /// Preview of the inviter (from GET /auth/invite/:handle).
  Map<String, dynamic>? invitePreview;

  /// Conversation opened after accepting an invite (DM with inviter).
  String? _pendingOpenConversationId;

  /// Saved AI profiles (key + model). Device-local.
  List<AiProfile> aiProfiles = [];

  /// Which profile is selected for # commands.
  String? activeAiProfileId;

  /// Opt-in master switch.
  bool aiEnabled = false;

  /// Play a sound on incoming messages (device-local, default on).
  bool soundEnabled = true;

  /// Show OS/browser notification toasts on incoming messages (device-local).
  bool notificationsEnabled = true;

  /// Prefer lower RAM/CPU: static emoji, lazy video, capped image decode.
  /// Defaults on for Linux desktop (old notebooks); off elsewhere unless set.
  bool lowResourceMode = false;

  /// App appearance mode (device-local). Applied by the root [MaterialApp].
  ThemeMode themeMode = ThemeMode.dark;

  /// Chosen accent seed (device-local). Derived per light/dark in PrivetTheme.
  Color accent = const Color(0xFFB6F24A);

  /// Where # AI commands are allowed once enabled (legacy prefs; sharing is # vs #me).
  AiUsageScope aiScope = AiUsageScope.onlyMe;

  /// From GET /ai/status — server env defaults (never includes secret values).
  bool serverAiConfigured = false;
  String? serverAiProvider;
  String? serverDeepseekModel;
  String? serverGeminiModel;

  AiProfile? get activeAiProfile {
    if (aiProfiles.isEmpty) return null;
    final id = activeAiProfileId;
    if (id != null) {
      for (final p in aiProfiles) {
        if (p.id == id) return p;
      }
    }
    return aiProfiles.first;
  }

  String get aiApiKey => activeAiProfile?.apiKey.trim() ?? '';
  String get aiModel => activeAiProfile?.model.trim() ?? '';
  String get aiBaseUrl => activeAiProfile?.baseUrl.trim() ?? '';

  /// True when AI is on and the active profile has a key + model.
  bool get aiActive => aiEnabled && (activeAiProfile?.isReady ?? false);

  /// Provider hint from the active key (for request routing).
  String get aiProviderId {
    final key = aiApiKey;
    if (key.startsWith('AIza')) return 'gemini';
    if (key.isNotEmpty) return 'openai';
    final server = serverAiProvider ?? '';
    if (server == 'deepseek') return 'openai';
    return server;
  }

  /// Model id sent with requests / shown in UI (no vendor prefix).
  String get aiModelId {
    final custom = aiModel;
    if (custom.isNotEmpty) return custom;
    final provider = aiProviderId;
    if (provider == 'gemini') {
      return serverGeminiModel?.trim().isNotEmpty == true
          ? serverGeminiModel!.trim()
          : 'gemini-2.5-flash-lite';
    }
    if (provider == 'openai' || provider == 'deepseek') {
      return serverDeepseekModel?.trim().isNotEmpty == true
          ? serverDeepseekModel!.trim()
          : '';
    }
    return '';
  }

  /// Badges / composer: model id only.
  String get aiModelLabel {
    if (!aiActive) return '';
    return aiModelId;
  }

  /// Composer hint: plain when AI is off, model + # / #me tip when active.
  String get composerPlaceholder {
    if (!aiActive) return 'Message';
    return '$aiModelLabel · # shared · #me private';
  }

  ActiveCall? ringing;
  CallSession? callSession;

  /// When true, active call is a small floating bar so chat stays usable.
  bool callMinimized = false;

  /// Floating mini-call bar position (top-left); null → default bottom-right.
  Offset? miniCallOffset;

  /// Floating mini-call bar size.
  Size miniCallSize = const Size(480, 120);

  /// Held between Share click and call.accepted (Firefox transient activation).
  MediaStream? _pendingDisplayStream;

  /// Mic/camera opened on the call-icon click — reused on accept (no second prompt).
  MediaStream? _pendingLocalStream;

  /// Local mic/camera held while the outgoing ring UI is up (self-preview).
  MediaStream? get pendingLocalStream => _pendingLocalStream;

  /// User cancelled while invite was still awaiting server `call.ringing`.
  bool _cancelOutgoingWhenRinging = false;

  void setCallMinimized(bool value) {
    if (callMinimized == value) return;
    callMinimized = value;
    notifyCall();
    // Web: remounting RTCVideoView needs a post-frame srcObject rebind or the
    // camera/remote video stays on a frozen/black frame.
    final session = callSession;
    if (session == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!identical(callSession, session)) return;
      session.rebindRenderers();
      wakeUiAfterMediaDialog();
    });
  }

  void setMiniCallOffset(Offset value) {
    miniCallOffset = value;
    // Intentionally does not notify — drag UI keeps local state; persist on end.
  }

  void setMiniCallSize(Size value) {
    miniCallSize = Size(
      value.width.clamp(320.0, 720.0),
      value.height.clamp(96.0, 520.0),
    );
    // Intentionally does not notify — resize UI keeps local state.
  }

  void commitMiniCallLayout({Offset? offset, Size? size}) {
    if (offset != null) miniCallOffset = offset;
    if (size != null) {
      miniCallSize = Size(
        size.width.clamp(320.0, 720.0),
        size.height.clamp(96.0, 520.0),
      );
    }
    notifyCall();
  }

  void resetMiniCallLayout() {
    miniCallOffset = null;
    miniCallSize = const Size(480, 120);
  }

  void _bump(ValueNotifier<int> tick) => tick.value++;

  void notifySession() {
    _bump(sessionTick);
    super.notifyListeners();
    _syncBrowserTabIndicator();
  }

  void notifyShell() {
    _bump(shellTick);
    super.notifyListeners();
  }

  void notifyInbox() {
    _bump(inboxTick);
    super.notifyListeners();
  }

  void notifyChat() {
    _bump(chatTick);
    super.notifyListeners();
  }

  void notifyTypingOnly() {
    _bump(typingTick);
  }

  void notifyCall() {
    _bump(callTick);
    super.notifyListeners();
    _syncBrowserTabIndicator();
  }

  void notifyChatAndInbox() {
    _bump(chatTick);
    _bump(inboxTick);
    super.notifyListeners();
  }

  @override
  void notifyListeners() {
    // Default broad notify — prefer scoped helpers above when possible.
    _bump(inboxTick);
    _bump(chatTick);
    _bump(shellTick);
    _bump(callTick);
    _bump(sessionTick);
    super.notifyListeners();
    _syncBrowserTabIndicator();
  }

  void _syncBrowserTabIndicator() {
    final ring = ringing;
    if (ring != null) {
      final label = switch (ring.call.mode) {
        'screen' =>
          ring.phase == CallPhase.incoming
              ? 'Incoming screen share'
              : 'Starting screen share',
        'video' =>
          ring.phase == CallPhase.incoming ? 'Incoming video call' : 'Calling',
        _ => ring.phase == CallPhase.incoming ? 'Incoming call' : 'Calling',
      };
      setBrowserTabTitle('● $label — Privet');
      return;
    }
    final session = callSession;
    if (session != null) {
      final label = switch (session.call.mode) {
        'screen' when session.isSharingLocally => 'Sharing your screen',
        'screen' when session.peerSharingScreen => 'Watching screen share',
        'screen' => 'Screen call',
        'video' => 'Video call',
        _ => 'On a call',
      };
      setBrowserTabTitle('● $label — Privet');
      return;
    }
    setBrowserTabTitle(null);
  }

  ApiClient get api => _api;
  RealtimeClient get rt => _rt;

  Future<SharedPreferences> _prefs() async {
    return _prefsCache ??= await SharedPreferences.getInstance();
  }

  Future<void> bootstrap() async {
    _readInviteFromUrl();
    final prefs = await _prefs();
    _loadAiProfiles(prefs);
    aiEnabled = prefs.getBool('privet_ai_enabled') ?? false;
    soundEnabled = prefs.getBool('privet_sound_enabled') ?? true;
    notificationsEnabled =
        prefs.getBool('privet_notifications_enabled') ?? true;
    themeMode = _themeModeFromStorage(prefs.getString('privet_theme_mode'));
    final accentValue = prefs.getInt('privet_accent');
    if (accentValue != null) accent = Color(accentValue);
    // Low RAM & CPU: default on for Linux (old notebooks); elsewhere off.
    final storedLow = prefs.getBool('privet_low_resource');
    lowResourceMode = storedLow ??
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux);
    privetLowResourceEmoji = lowResourceMode;
    aiScope = AiUsageScopeX.fromStorage(prefs.getString('privet_ai_scope'));
    if (aiEnabled && !aiActive) {
      aiEnabled = false;
    }
    final token = prefs.getString('privet_token');
    if (token != null) {
      _api.token = token;
      try {
        user = await _api.me();
        await _rt.connect(token);
        await refreshInbox();
        unawaited(refreshAiStatus());
        unawaited(ensureNotificationPermission());
        unawaited(initMobilePush());
        unawaited(refreshBlocked());
        // Already signed in + opened someone's invite link → open their DM.
        if (pendingInviteHandle != null) {
          await _openInviteDm(pendingInviteHandle!);
          clearPendingInvite();
        }
      } catch (_) {
        await logout();
      }
    } else if (pendingInviteHandle != null) {
      unawaited(loadInvitePreview(pendingInviteHandle!));
    }
    booting = false;
    notifySession();
  }

  Future<void> setSoundEnabled(bool value) async {
    soundEnabled = value;
    notifySession();
    final prefs = await _prefs();
    await prefs.setBool('privet_sound_enabled', value);
  }

  Future<void> setNotificationsEnabled(bool value) async {
    notificationsEnabled = value;
    notifySession();
    if (value) unawaited(ensureNotificationPermission());
    final prefs = await _prefs();
    await prefs.setBool('privet_notifications_enabled', value);
  }

  Future<void> setLowResourceMode(bool value) async {
    if (lowResourceMode == value) return;
    lowResourceMode = value;
    privetLowResourceEmoji = value;
    notifySession();
    final prefs = await _prefs();
    await prefs.setBool('privet_low_resource', value);
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifySession();
    final prefs = await _prefs();
    await prefs.setString('privet_theme_mode', value.name);
  }

  Future<void> setAccent(Color value) async {
    accent = value;
    notifySession();
    final prefs = await _prefs();
    await prefs.setInt('privet_accent', value.toARGB32());
  }

  static ThemeMode _themeModeFromStorage(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.dark;
    }
  }

  void _readInviteFromUrl() {
    // Use window.location on web — Uri.base follows <base href> and drops ?invite=.
    final invite = currentPageUri().queryParameters['invite']
        ?.trim()
        .toLowerCase();
    if (invite != null && invite.isNotEmpty) {
      pendingInviteHandle = invite;
    }
  }

  /// Shareable invite URL for the current user (one-click join + DM).
  String? inviteLink() {
    final me = user;
    if (me == null) return null;
    final origin = currentPageUri().origin;
    // Prefer the live page origin (web). Fall back to API host for native.
    final base = (origin.isNotEmpty && !origin.startsWith('file:'))
        ? origin
        : _api.baseUrl;
    return '$base/?invite=${Uri.encodeComponent(me.handle)}';
  }

  Future<void> loadInvitePreview(String handle) async {
    try {
      invitePreview = await _api.inviteInfo(handle);
      notifyListeners();
    } catch (_) {
      invitePreview = null;
      notifyListeners();
    }
  }

  void clearPendingInvite() {
    pendingInviteHandle = null;
    invitePreview = null;
    notifyListeners();
  }

  /// Extract invite handle from a pasted URL (`?invite=…`) or bare `@handle`.
  static String? parseInviteHandle(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri != null && uri.hasScheme) {
      final fromQuery = uri.queryParameters['invite']?.trim().toLowerCase();
      if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
    }
    // Also accept `…/?invite=foo` pasted without a scheme.
    final match = RegExp(
      r'[?&]invite=([^&\s#]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) {
      return Uri.decodeComponent(match.group(1)!).trim().toLowerCase();
    }
    var handle = text;
    if (handle.startsWith('@')) handle = handle.substring(1);
    handle = handle.trim().toLowerCase();
    if (handle.isEmpty) return null;
    return handle;
  }

  /// Paste invite link / @handle → open DM with that user.
  Future<void> openInviteFromPaste(String raw) async {
    final handle = parseInviteHandle(raw);
    if (handle == null || handle.isEmpty) {
      throw ApiException(400, 'Paste an invite link or @handle');
    }
    await _openInviteDm(handle, throwOnMiss: true);
  }

  Future<void> _openInviteDm(String handle, {bool throwOnMiss = false}) async {
    try {
      PrivetUser? peer;
      for (final u in directory) {
        if (u.handle.toLowerCase() == handle.toLowerCase()) {
          peer = u;
          break;
        }
      }
      // Directory can lag or omit users — resolve via public invite preview.
      if (peer == null) {
        final info = await _api.inviteInfo(handle);
        final id = info['id'] as String?;
        if (id == null || id.isEmpty) {
          if (throwOnMiss) throw ApiException(404, 'Invite not found');
          return;
        }
        peer = PrivetUser(
          id: id,
          handle: (info['handle'] as String?) ?? handle,
          displayName: (info['displayName'] as String?) ?? handle,
          avatarHue: (info['avatarHue'] as num?)?.toInt() ?? 160,
          avatarUrl: info['avatarUrl'] as String?,
        );
      }
      if (peer.id == user?.id) {
        if (throwOnMiss) throw ApiException(400, 'That’s your own invite');
        return;
      }
      await openDm(peer);
    } catch (e) {
      if (throwOnMiss) rethrow;
      // Invite target missing / blocked — ignore on auto-open.
    }
  }

  Future<void> _finishPendingInvite() async {
    final invite = pendingInviteHandle;
    if (invite == null || invite.isEmpty) return;
    await _openInviteDm(invite);
    clearPendingInvite();
  }

  void _loadAiProfiles(SharedPreferences prefs) {
    final raw = prefs.getString('privet_ai_profiles');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          aiProfiles = list
              .whereType<Map>()
              .map((e) => AiProfile.fromJson(Map<String, dynamic>.from(e)))
              .where((p) => p.id.isNotEmpty)
              .map((p) {
                // Pre–base-URL profiles assumed DeepSeek's OpenAI-compatible host.
                if (!p.isGeminiKey &&
                    p.apiKey.trim().isNotEmpty &&
                    p.baseUrl.trim().isEmpty) {
                  p.baseUrl = 'https://api.deepseek.com';
                }
                return p;
              })
              .toList();
        }
      } catch (_) {
        aiProfiles = [];
      }
    }
    // Migrate legacy single key/model.
    if (aiProfiles.isEmpty) {
      final legacyKey = prefs.getString('privet_ai_api_key')?.trim() ?? '';
      final legacyModel = prefs.getString('privet_ai_model')?.trim() ?? '';
      if (legacyKey.isNotEmpty) {
        aiProfiles = [
          AiProfile(
            id: _uuid.v4(),
            apiKey: legacyKey,
            model: legacyModel.isNotEmpty ? legacyModel : '',
            baseUrl: legacyKey.startsWith('AIza')
                ? ''
                : 'https://api.deepseek.com',
          ),
        ];
      }
    }
    activeAiProfileId = prefs.getString('privet_ai_active_id');
    if (activeAiProfileId != null &&
        !aiProfiles.any((p) => p.id == activeAiProfileId)) {
      activeAiProfileId = aiProfiles.isEmpty ? null : aiProfiles.first.id;
    } else if (activeAiProfileId == null && aiProfiles.isNotEmpty) {
      activeAiProfileId = aiProfiles.first.id;
    }
  }

  Future<void> _persistAiProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'privet_ai_profiles',
      jsonEncode(aiProfiles.map((p) => p.toJson()).toList()),
    );
    if (activeAiProfileId == null || activeAiProfileId!.isEmpty) {
      await prefs.remove('privet_ai_active_id');
    } else {
      await prefs.setString('privet_ai_active_id', activeAiProfileId!);
    }
    // Keep legacy keys in sync for older builds.
    final active = activeAiProfile;
    if (active == null || active.apiKey.trim().isEmpty) {
      await prefs.remove('privet_ai_api_key');
      await prefs.remove('privet_ai_model');
    } else {
      await prefs.setString('privet_ai_api_key', active.apiKey.trim());
      await prefs.setString('privet_ai_model', active.model.trim());
    }
  }

  Future<void> setActiveAiProfile(String id) async {
    if (!aiProfiles.any((p) => p.id == id)) return;
    activeAiProfileId = id;
    await _persistAiProfiles();
    notifyListeners();
  }

  Future<AiProfile> upsertAiProfile({
    String? id,
    required String apiKey,
    required String model,
    String baseUrl = '',
  }) async {
    final key = apiKey.trim();
    final mod = model.trim();
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (key.isEmpty) {
      throw StateError('API key is required');
    }
    if (mod.isEmpty) {
      throw StateError('Model id is required');
    }
    final isGemini = key.startsWith('AIza');
    if (!isGemini && base.isEmpty) {
      throw StateError('Base URL is required for OpenAI-compatible providers');
    }
    final existingId = id;
    if (existingId != null) {
      final idx = aiProfiles.indexWhere((p) => p.id == existingId);
      if (idx >= 0) {
        aiProfiles[idx].apiKey = key;
        aiProfiles[idx].model = mod;
        aiProfiles[idx].baseUrl = isGemini ? '' : base;
        await _persistAiProfiles();
        notifyListeners();
        return aiProfiles[idx];
      }
    }
    final profile = AiProfile(
      id: _uuid.v4(),
      apiKey: key,
      model: mod,
      baseUrl: isGemini ? '' : base,
    );
    aiProfiles = [...aiProfiles, profile];
    activeAiProfileId ??= profile.id;
    await _persistAiProfiles();
    notifyListeners();
    return profile;
  }

  Future<void> deleteAiProfile(String id) async {
    aiProfiles = aiProfiles.where((p) => p.id != id).toList();
    if (activeAiProfileId == id) {
      activeAiProfileId = aiProfiles.isEmpty ? null : aiProfiles.first.id;
    }
    if (aiProfiles.isEmpty && aiEnabled) {
      aiEnabled = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('privet_ai_enabled', false);
    }
    await _persistAiProfiles();
    notifyListeners();
  }

  Future<void> setAiEnabled(bool enabled) async {
    if (enabled && !(activeAiProfile?.isReady ?? false)) {
      throw StateError(
        'Add an AI (key + model, and base URL if needed) before enabling',
      );
    }
    aiEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('privet_ai_enabled', enabled);
    notifyListeners();
  }

  Future<void> setAiScope(AiUsageScope scope) async {
    aiScope = scope;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('privet_ai_scope', scope.storageValue);
    notifyListeners();
  }

  Future<void> refreshAiStatus() async {
    try {
      final data = await _api.aiStatus();
      serverAiConfigured = data['configured'] == true;
      final p = data['activeProvider']?.toString();
      serverAiProvider = (p == null || p.isEmpty) ? null : p;
      final dm = data['deepseekModel']?.toString();
      serverDeepseekModel = (dm == null || dm.isEmpty) ? null : dm;
      final gm = data['geminiModel']?.toString();
      serverGeminiModel = (gm == null || gm.isEmpty) ? null : gm;
      notifyListeners();
    } catch (_) {
      // Keep last known status.
    }
  }

  Future<void> login(String handle, String password) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final data = await _api.login(handle.trim(), password);
      await _acceptSession(data);
      await _finishPendingInvite();
    } catch (e) {
      error = _friendlyError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> register({
    required String handle,
    required String password,
    String? displayName,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final data = await _api.register(
        handle: handle.trim(),
        password: password,
        displayName: displayName,
      );
      await _acceptSession(data);
      await _finishPendingInvite();
    } catch (e) {
      error = _friendlyError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> quickJoin({String? inviteHandle}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final invite = (inviteHandle ?? pendingInviteHandle)?.trim();
      final data = await _api.quickJoin(inviteHandle: invite);
      final conversationId = data['conversationId'] as String?;
      if (conversationId != null && conversationId.isNotEmpty) {
        _pendingOpenConversationId = conversationId;
      }
      await _acceptSession(data);
      final creds = data['credentials'] as Map<String, dynamic>?;
      if (creds != null) {
        welcomeCredentials = {
          'handle': creds['handle'] as String,
          'password': creds['password'] as String,
        };
      }
      clearPendingInvite();
    } catch (e) {
      error = _friendlyError(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void clearWelcomeCredentials() {
    welcomeCredentials = null;
    notifyListeners();
  }

  void setError(String? message) {
    error = message;
    notifyListeners();
  }

  Future<void> _acceptSession(Map<String, dynamic> data) async {
    _api.token = data['token'] as String;
    user = PrivetUser.fromJson(data['user'] as Map<String, dynamic>);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('privet_token', _api.token!);
    await _rt.connect(_api.token!);
    await refreshInbox();
    final openId = _pendingOpenConversationId;
    _pendingOpenConversationId = null;
    if (openId != null) {
      await openConversation(openId);
    }
    unawaited(refreshAiStatus());
    unawaited(ensureNotificationPermission());
    unawaited(initMobilePush());
    unawaited(refreshBlocked());
  }

  String _friendlyError(Object e) {
    if (e is ApiException) return e.message;
    return e.toString();
  }

  Future<void> logout() async {
    await endCall(local: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('privet_token');
    await _rt.disconnect();
    _api.token = null;
    user = null;
    conversations = [];
    messagesByChat.clear();
    historyLoaded.clear();
    _historyLoading.clear();
    hasMoreByChat.clear();
    loadingOlder.clear();
    _pendingWsMessages.clear();
    tasksByChat.clear();
    online.clear();
    lastSeen.clear();
    blocked = [];
    activeConversationId = null;
    ringing = null;
    notifyListeners();
  }

  Future<void> refreshInbox() async {
    conversations = await _api.conversations();
    directory = await _api.users();
    notifyInbox();
  }

  /// Coalesce structural inbox refreshes so rapid messages don't hammer HTTP.
  void _scheduleInboxReconcile() {
    _inboxReconcileTimer?.cancel();
    _inboxReconcileTimer = Timer(const Duration(seconds: 3), () {
      unawaited(refreshInbox().catchError((_) {}));
    });
  }

  String _sqlTimestamp(DateTime dt) =>
      dt.toUtc().toIso8601String().replaceFirst('T', ' ').split('.').first;

  List<ChatMessage> _mergeMessages(
    List<ChatMessage> base,
    List<ChatMessage> extra,
  ) {
    final byId = <String, ChatMessage>{};
    for (final m in base) {
      byId[m.id] = m;
    }
    for (final m in extra) {
      byId[m.id] = m;
    }
    final merged = byId.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return merged;
  }

  void _applyPendingMessages(String id) {
    final pending = _pendingWsMessages.remove(id);
    if (pending == null || pending.isEmpty) return;
    var list = List<ChatMessage>.from(messagesByChat[id] ?? const []);
    for (final message in pending) {
      if (!list.any((m) => m.id == message.id)) {
        list.add(message);
      }
    }
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    messagesByChat[id] = list;
  }

  Future<void> ensureHistory(String id) async {
    if (historyLoaded.contains(id) || _historyLoading.contains(id)) return;
    _historyLoading.add(id);
    try {
      final remote = await _api.messages(id, limit: messagePageSize);
      final existing = messagesByChat[id] ?? const <ChatMessage>[];
      messagesByChat[id] = _mergeMessages(remote, existing);
      hasMoreByChat[id] = remote.length >= messagePageSize;
      historyLoaded.add(id);
      _applyPendingMessages(id);
      notifyListeners();
    } catch (e) {
      // Keep key absent so a later open/WS retry can load history.
      if (!historyLoaded.contains(id)) {
        messagesByChat.remove(id);
      }
      rethrow;
    } finally {
      _historyLoading.remove(id);
    }
  }

  Future<bool> loadOlderMessages(String id) async {
    if (!historyLoaded.contains(id)) return false;
    if (hasMoreByChat[id] == false) return false;
    if (loadingOlder.contains(id)) return false;
    final list = messagesByChat[id];
    if (list == null || list.isEmpty) {
      hasMoreByChat[id] = false;
      notifyListeners();
      return false;
    }
    loadingOlder.add(id);
    notifyListeners();
    try {
      final oldest = list.first;
      final older = await _api.messages(
        id,
        limit: messagePageSize,
        before: _sqlTimestamp(oldest.createdAt),
      );
      if (older.isEmpty) {
        hasMoreByChat[id] = false;
        return false;
      }
      messagesByChat[id] = _mergeMessages(older, list);
      hasMoreByChat[id] = older.length >= messagePageSize;
      return true;
    } finally {
      loadingOlder.remove(id);
      notifyListeners();
    }
  }

  /// Ensure [messageId] is present in the local cache, loading older pages if needed.
  Future<bool> ensureMessageLoaded(String chatId, String messageId) async {
    await ensureHistory(chatId);
    for (var i = 0; i < 30; i++) {
      final list = messagesByChat[chatId] ?? const <ChatMessage>[];
      if (list.any((m) => m.id == messageId)) return true;
      if (hasMoreByChat[chatId] == false) return false;
      final loaded = await loadOlderMessages(chatId);
      if (!loaded) return false;
    }
    return false;
  }

  Future<List<ChatMessage>> searchInConversation(
    String conversationId,
    String query,
  ) => _api.searchInConversation(conversationId, query);

  Future<void> openConversation(String id) async {
    activeConversationId = id;
    typingUserId = null;
    final idx = conversations.indexWhere((c) => c.id == id);
    if (idx >= 0) {
      final lr = conversations[idx].lastReadAt;
      _aiUnreadSince[id] = lr == null
          ? null
          : lr
                .toUtc()
                .toIso8601String()
                .replaceFirst('T', ' ')
                .split('.')
                .first;
    }
    try {
      await ensureHistory(id);
    } catch (e) {
      error = _friendlyError(e);
    }
    if (!tasksByChat.containsKey(id)) {
      try {
        tasksByChat[id] = await _api.tasks(id);
      } catch (_) {
        tasksByChat[id] = [];
      }
    }
    // Clear unread locally right away, then sync read cursor.
    if (idx >= 0 && conversations[idx].unreadCount > 0) {
      conversations[idx] = conversations[idx].copyWith(unreadCount: 0);
    }
    notifyShell();
    notifyChatAndInbox();
    // Mark read only when this window is focused and recently used.
    if (_canMarkReadNow) {
      _markRead(id, reason: 'openConversation');
    }
  }

  void attachChatSurface(String conversationId) {
    _surfaceChatId = conversationId;
    if (conversationId == activeConversationId && _canMarkReadNow) {
      final idx = conversations.indexWhere((c) => c.id == conversationId);
      if (idx >= 0 && conversations[idx].unreadCount > 0) {
        conversations[idx] = conversations[idx].copyWith(unreadCount: 0);
        notifyListeners();
      }
      _markRead(conversationId, reason: 'attachChatSurface');
    }
  }

  void detachChatSurface(String conversationId) {
    if (_surfaceChatId == conversationId) {
      _surfaceChatId = null;
    }
  }

  /// Call from UI pointer/keyboard activity so idle windows don't eat unread.
  void noteUserPresence() {
    _lastUserPresence = DateTime.now();
    unlockNotificationAudio();
  }

  bool get _userRecentlyPresent =>
      DateTime.now().difference(_lastUserPresence) <
      const Duration(seconds: 45);

  bool get _canMarkReadNow =>
      chatSurfaceMounted &&
      !documentHidden &&
      documentHasFocus &&
      _userRecentlyPresent;

  void _scheduleFocusedRead() {
    _focusedReadTimer?.cancel();
    _focusedReadTimer = Timer(const Duration(milliseconds: 400), () {
      final id = activeConversationId;
      if (id == null || !_canMarkReadNow) return;
      _markRead(id, reason: 'focusedRead');
    });
  }

  void _markRead(String conversationId, {String reason = ''}) {
    final list = messagesByChat[conversationId];
    final lastId = list != null && list.isNotEmpty ? list.last.id : null;
    final focused = _canMarkReadNow;
    _rt.markRead(
      conversationId: conversationId,
      messageId: lastId,
      focused: focused,
    );
    // Fire-and-forget HTTP too (survives if WS flaky).
    _api
        .markRead(conversationId, messageId: lastId, focused: focused)
        .catchError((_) => <String, dynamic>{});
  }

  Future<void> setMuted(String conversationId, {required bool muted}) async {
    await _api.setMuted(conversationId, muted: muted);
    final idx = conversations.indexWhere((c) => c.id == conversationId);
    if (idx >= 0) {
      conversations[idx] = conversations[idx].copyWith(muted: muted);
      notifyListeners();
    } else {
      await refreshInbox();
    }
  }

  Future<void> setPinned(String conversationId, {required bool pinned}) async {
    await _api.setPinned(conversationId, pinned: pinned);
    await refreshInbox();
  }

  Future<void> refreshBlocked() async {
    try {
      blocked = await _api.blockedUsers();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> blockUser(String userId) async {
    blocked = await _api.blockUser(userId);
    // Drop open DM with blocked peer from local inbox view.
    conversations.removeWhere((c) => !c.isGroup && c.peer?.id == userId);
    if (activeConversationId != null &&
        !conversations.any((c) => c.id == activeConversationId)) {
      activeConversationId = null;
    }
    directory.removeWhere((u) => u.id == userId);
    notifyListeners();
    await refreshInbox();
  }

  Future<void> unblockUser(String userId) async {
    blocked = await _api.unblockUser(userId);
    notifyListeners();
    await refreshInbox();
  }

  Future<void> updateProfile({
    String? displayName,
    String? avatarUrl,
    int? avatarHue,
    bool clearAvatar = false,
  }) async {
    user = await _api.updateProfile(
      displayName: displayName,
      avatarUrl: avatarUrl,
      avatarHue: avatarHue,
      clearAvatar: clearAvatar,
    );
    notifyListeners();
  }

  Future<void> forwardMessage({
    required String messageId,
    required String toConversationId,
  }) async {
    final message = await _api.forwardMessage(
      conversationId: toConversationId,
      messageId: messageId,
    );
    final list = List<ChatMessage>.from(messagesByChat[toConversationId] ?? []);
    if (!list.any((m) => m.id == message.id)) {
      list.add(message);
      messagesByChat[toConversationId] = list;
    }
    notifyListeners();
    await refreshInbox();
  }

  DateTime? lastSeenFor(String? userId) {
    if (userId == null) return null;
    return lastSeen[userId];
  }

  String presenceLabel(String? userId) {
    if (userId == null) return '';
    if (online.contains(userId)) return 'online';
    final at = lastSeen[userId];
    if (at == null) return 'offline';
    return 'last seen ${_formatLastSeen(at)}';
  }

  static String _formatLastSeen(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24 && now.day == local.day) {
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return 'today $h:$m';
    }
    if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    }
    return '${local.day}/${local.month}/${local.year}';
  }

  Future<void> initMobilePush() async {
    if (kIsWeb) return;
    try {
      final token = await registerMobilePushToken();
      if (token == null || token.isEmpty) return;
      final platform = defaultTargetPlatform == TargetPlatform.iOS
          ? 'ios'
          : 'android';
      await _api.registerDeviceToken(token: token, platform: platform);
    } catch (_) {}
  }

  Future<void> editMessage(String messageId, String body) async {
    final text = expandEmoticons(body.trim());
    if (text.isEmpty) return;
    _rt.editMessage(messageId: messageId, body: text);
  }

  Future<void> deleteMessage(String messageId) async {
    _rt.deleteMessage(messageId: messageId);
  }

  Future<SearchResults> search(String query) => _api.search(query);

  Future<void> ensureNotificationPermission() async {
    if (!kIsWeb) return;
    if (notificationsGranted) return;
    await requestNotificationPermission();
  }

  static String _draftKey(String conversationId) =>
      'privet_draft_$conversationId';

  Future<String> loadDraft(String conversationId) async {
    final prefs = await _prefs();
    return prefs.getString(_draftKey(conversationId)) ?? '';
  }

  Future<void> saveDraft(String conversationId, String text) async {
    if (_lastDraftText == text) return;
    _lastDraftText = text;
    final prefs = await _prefs();
    final trimmed = text; // keep whitespace drafts
    if (trimmed.isEmpty) {
      await prefs.remove(_draftKey(conversationId));
    } else {
      await prefs.setString(_draftKey(conversationId), trimmed);
    }
  }

  Future<void> clearDraft(String conversationId) async {
    _lastDraftText = '';
    final prefs = await _prefs();
    await prefs.remove(_draftKey(conversationId));
  }

  List<TaskItem> tasksFor(String? conversationId) {
    if (conversationId == null) return const [];
    return tasksByChat[conversationId] ?? const [];
  }

  ConversationTasks taskBoardFor(String? conversationId) =>
      ConversationTasks(items: List<TaskItem>.from(tasksFor(conversationId)));

  void _setTasks(String conversationId, List<TaskItem> items) {
    tasksByChat[conversationId] = items;
    notifyListeners();
  }

  Future<void> addTask({
    required String conversationId,
    required String body,
    String? messageId,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
  }) async {
    final items = await _api.createTask(
      conversationId: conversationId,
      body: body,
      messageId: messageId,
      mediaUrl: mediaUrl,
      mimeType: mimeType,
      fileName: fileName,
    );
    _setTasks(conversationId, items);
  }

  Future<void> addMessageToTask(ChatMessage message) async {
    final body = message.body.trim().isNotEmpty
        ? message.body.trim()
        : switch (message.kind) {
            'image' => 'Photo',
            'video' => 'Video',
            'audio' => 'Audio',
            'voice' => 'Voice message',
            'file' => message.fileName ?? 'File',
            'album' => '${message.mediaItems.length} attachments',
            _ => 'Message',
          };
    MediaAttachment? media;
    for (final item in message.mediaItems) {
      if (item.kind == 'image') {
        media = item;
        break;
      }
    }
    media ??= message.mediaItems.isNotEmpty ? message.mediaItems.first : null;
    await addTask(
      conversationId: message.conversationId,
      body: body,
      messageId: message.id,
      mediaUrl: media?.mediaUrl,
      mimeType: media?.mimeType,
      fileName: media?.fileName,
    );
  }

  Future<void> toggleTaskDone(TaskItem item) async {
    final items = await _api.updateTask(taskId: item.id, done: !item.done);
    _setTasks(item.conversationId, items);
  }

  Future<void> updateTaskBody(TaskItem item, String body) async {
    final items = await _api.updateTask(taskId: item.id, body: body);
    _setTasks(item.conversationId, items);
  }

  Future<void> attachTaskMedia({
    required TaskItem item,
    required String mediaUrl,
    String? mimeType,
    String? fileName,
  }) async {
    final items = await _api.updateTask(
      taskId: item.id,
      mediaUrl: mediaUrl,
      mimeType: mimeType,
      fileName: fileName,
    );
    _setTasks(item.conversationId, items);
  }

  Future<void> clearTaskMedia(TaskItem item) async {
    final items = await _api.updateTask(taskId: item.id, clearMedia: true);
    _setTasks(item.conversationId, items);
  }

  Future<void> deleteTask(TaskItem item) async {
    final items = await _api.deleteTask(item.id);
    _setTasks(item.conversationId, items);
  }

  Future<void> clearDoneTasks(String conversationId) async {
    final items = await _api.clearDoneTasks(conversationId);
    _setTasks(conversationId, items);
  }

  Future<void> openDm(PrivetUser peer) async {
    final conversation = await _api.openDm(peer.id);
    await refreshInbox();
    await openConversation(conversation.id);
  }

  Future<void> createGroup({
    required String title,
    required List<String> memberIds,
  }) async {
    final conversation = await _api.createGroup(
      title: title,
      memberIds: memberIds,
    );
    await refreshInbox();
    await openConversation(conversation.id);
  }

  Future<List<PrivetUser>> addGroupMember({
    required String conversationId,
    required String userId,
  }) async {
    final members = await _api.addMember(conversationId, userId);
    await refreshInbox();
    notifyListeners();
    return members;
  }

  void _clearChatCache(String conversationId) {
    messagesByChat.remove(conversationId);
    historyLoaded.remove(conversationId);
    _historyLoading.remove(conversationId);
    hasMoreByChat.remove(conversationId);
    loadingOlder.remove(conversationId);
    _pendingWsMessages.remove(conversationId);
    tasksByChat.remove(conversationId);
  }

  Future<List<PrivetUser>> removeGroupMember({
    required String conversationId,
    required String userId,
  }) async {
    final members = await _api.removeMember(conversationId, userId);
    final left = userId == user?.id;
    if (left) {
      _clearChatCache(conversationId);
      if (activeConversationId == conversationId) {
        activeConversationId = null;
      }
    }
    await refreshInbox();
    notifyListeners();
    return members;
  }

  Future<void> deleteGroup(String conversationId) async {
    await _api.deleteGroup(conversationId);
    _clearChatCache(conversationId);
    if (activeConversationId == conversationId) {
      activeConversationId = null;
    }
    await refreshInbox();
    notifyListeners();
  }

  Future<void> deleteConversation(String conversationId) async {
    await _api.deleteConversation(conversationId);
    _clearChatCache(conversationId);
    if (activeConversationId == conversationId) {
      activeConversationId = null;
    }
    await refreshInbox();
    notifyListeners();
  }

  Future<void> hideConversation(String conversationId) async {
    await _api.hideConversation(conversationId);
    _clearChatCache(conversationId);
    if (activeConversationId == conversationId) {
      activeConversationId = null;
    }
    await refreshInbox();
    notifyListeners();
  }

  void sendText(
    String body, {
    String? replyToId,
    ReplyPreview? replyTo,
    String? replyQuote,
  }) {
    final chatId = activeConversationId;
    final me = user;
    if (chatId == null || me == null) return;
    final text = expandEmoticons(body.trim());
    if (text.isEmpty) return;

    if (text.startsWith('#')) {
      unawaited(sendAiCommand(text));
      unawaited(clearDraft(chatId));
      return;
    }

    final clientId = _uuid.v4();
    final optimistic = ChatMessage(
      id: clientId,
      conversationId: chatId,
      body: text,
      kind: 'text',
      createdAt: DateTime.now(),
      sender: me,
      replyToId: replyToId,
      replyTo: replyTo,
      pending: true,
    );
    messagesByChat.putIfAbsent(chatId, () => []);
    messagesByChat[chatId] = [...messagesByChat[chatId]!, optimistic];
    notifyListeners();

    _rt.sendMessage(
      conversationId: chatId,
      body: text,
      clientId: clientId,
      replyToId: replyToId,
      replyQuote: replyQuote,
    );
    unawaited(clearDraft(chatId));
  }

  static const String _aiHelp = '''Privet AI

# summarize — unread (shared with chat)
# summarize 40 — last 40 messages (shared)
# <question> — ask about this chat (shared)

#me summarize — same, but only you see Q+A
#me <question> — private answer only for you

Enable AI in Profile & settings and add your API key.

Examples:
# what did we decide?
#me draft a reply to Mira''';

  /// `#me …` → private; plain `# …` → shared with the chat.
  static ({bool private, String apiInput, String displayQuestion})
  _parseAiCommandLine(String input) {
    final trimmed = input.trim();
    final me = RegExp(
      r'^#\s*me\b\s*',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (me != null) {
      final rest = trimmed.substring(me.end).trim();
      final apiInput = rest.isEmpty ? '# help' : '# $rest';
      return (private: true, apiInput: apiInput, displayQuestion: trimmed);
    }
    return (private: false, apiInput: trimmed, displayQuestion: trimmed);
  }

  Future<void> sendAiCommand(String input) async {
    final chatId = activeConversationId;
    final me = user;
    if (chatId == null || me == null) return;
    final trimmed = input.trim();
    if (!trimmed.startsWith('#')) return;

    final parsed = _parseAiCommandLine(trimmed);
    final apiCmd = parsed.apiInput.substring(1).trim();
    if (apiCmd.isEmpty || apiCmd.toLowerCase() == 'help' || apiCmd == '?') {
      _appendAiBubble(chatId, _aiHelp);
      return;
    }

    if (!aiEnabled) {
      _appendAiBubble(
        chatId,
        'Privet AI is off. Open Profile & settings, turn it on, '
        'and add an AI (API key + model; OpenAI-compatible needs a base URL).',
      );
      return;
    }
    if (aiApiKey.trim().isEmpty) {
      _appendAiBubble(
        chatId,
        'Add an AI API key in Profile & settings to use AI.',
      );
      return;
    }

    final share = !parsed.private;

    final thinkingId = _uuid.v4();
    _appendAiBubble(
      chatId,
      AiTurnPayload(
        question: parsed.displayQuestion,
        answer: 'Thinking…',
        provider: aiProviderId.isEmpty ? null : aiProviderId,
        model: aiModelId.isEmpty ? null : aiModelId,
        private: parsed.private,
      ).encode(),
      id: thinkingId,
      pending: true,
    );

    try {
      final since = _aiUnreadSince[chatId];
      final res = await _api.aiChat(
        chatId,
        input: parsed.apiInput,
        since: since,
        apiKey: aiApiKey,
        model: aiModel.trim().isEmpty ? null : aiModel.trim(),
        baseUrl: aiBaseUrl.isEmpty ? null : aiBaseUrl,
      );
      final text = (res['text'] as String?)?.trim() ?? '';
      final answer = text.isEmpty ? '(empty reply)' : text;
      final meta = res['meta'];
      String? provider;
      String? model;
      if (meta is Map) {
        provider = meta['provider']?.toString();
        model = meta['model']?.toString();
      }
      provider ??= aiProviderId.isEmpty ? null : aiProviderId;
      model ??= aiModelId.isEmpty ? null : aiModelId;

      final packed = AiTurnPayload(
        question: parsed.displayQuestion,
        answer: answer,
        provider: provider,
        model: model,
        private: parsed.private,
      ).encode();

      if (share) {
        _removeAiBubble(chatId, thinkingId);
        _postChatMessage(chatId: chatId, body: packed, kind: 'ai', sender: me);
      } else {
        _replaceAiBubble(chatId, thinkingId, packed);
      }
    } catch (e) {
      final err = e is ApiException ? e.message : e.toString();
      _replaceAiBubble(
        chatId,
        thinkingId,
        AiTurnPayload(
          question: parsed.displayQuestion,
          answer: err,
          provider: aiProviderId.isEmpty ? null : aiProviderId,
          model: aiModelId.isEmpty ? null : aiModelId,
          private: true,
        ).encode(),
      );
    }
  }

  void _postChatMessage({
    required String chatId,
    required String body,
    required String kind,
    required PrivetUser sender,
  }) {
    final clientId = _uuid.v4();
    final optimistic = ChatMessage(
      id: clientId,
      conversationId: chatId,
      body: body,
      kind: kind,
      createdAt: DateTime.now(),
      sender: sender,
      pending: true,
    );
    messagesByChat.putIfAbsent(chatId, () => []);
    messagesByChat[chatId] = [...messagesByChat[chatId]!, optimistic];
    notifyListeners();
    _rt.sendMessage(
      conversationId: chatId,
      body: body,
      kind: kind,
      clientId: clientId,
    );
  }

  void _appendAiBubble(
    String chatId,
    String body, {
    String? id,
    bool pending = false,
  }) {
    final me = user;
    if (me == null) return;
    final msg = ChatMessage(
      id: id ?? _uuid.v4(),
      conversationId: chatId,
      body: body,
      kind: 'text',
      createdAt: DateTime.now(),
      // Attribute to the asker so the bubble sits on "my" side of the chat.
      sender: me,
      pending: pending,
      aiLocal: true,
    );
    messagesByChat.putIfAbsent(chatId, () => []);
    messagesByChat[chatId] = [...messagesByChat[chatId]!, msg];
    notifyListeners();
  }

  void _replaceAiBubble(String chatId, String id, String body) {
    final list = messagesByChat[chatId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final updated = list[idx].copyWith(body: body, pending: false);
    final next = List<ChatMessage>.from(list);
    next[idx] = updated;
    messagesByChat[chatId] = next;
    notifyListeners();
  }

  void _removeAiBubble(String chatId, String id) {
    final list = messagesByChat[chatId];
    if (list == null) return;
    messagesByChat[chatId] = list
        .where((m) => m.id != id)
        .toList(growable: false);
    notifyListeners();
  }

  Future<void> sendMediaBytes({
    required List<int> bytes,
    required String filename,
    required String mimeType,
    String? caption,
    bool asVoice = false,
    String? replyToId,
    ReplyPreview? replyTo,
  }) async {
    await sendMediaAlbum(
      files: [(bytes: bytes, filename: filename, mimeType: mimeType)],
      caption: caption,
      asVoice: asVoice,
      replyToId: replyToId,
      replyTo: replyTo,
    );
  }

  Future<void> sendMediaAlbum({
    required List<({List<int> bytes, String filename, String mimeType})> files,
    String? caption,
    bool asVoice = false,
    String? replyToId,
    ReplyPreview? replyTo,
    String? replyQuote,
  }) async {
    final chatId = activeConversationId;
    final me = user;
    if (chatId == null || me == null || files.isEmpty) return;

    uploading = true;
    error = null;
    notifyListeners();
    try {
      final uploaded = <MediaAttachment>[];
      for (final file in files) {
        final up = await _api.uploadBytes(
          bytes: file.bytes,
          filename: file.filename,
          mimeType: file.mimeType,
          asVoice: asVoice && files.length == 1,
        );
        uploaded.add(
          MediaAttachment(
            mediaUrl: up.mediaUrl,
            kind: up.kind,
            mimeType: up.mimeType,
            fileName: up.fileName,
            fileSize: up.fileSize,
          ),
        );
      }

      final clientId = _uuid.v4();
      final body = expandEmoticons((caption ?? '').trim());
      final kind = uploaded.length > 1 ? 'album' : uploaded.first.kind;
      final first = uploaded.first;
      final optimistic = ChatMessage(
        id: clientId,
        conversationId: chatId,
        body: body,
        kind: kind,
        mediaUrl: first.mediaUrl,
        mimeType: first.mimeType,
        fileName: first.fileName,
        fileSize: first.fileSize,
        attachments: uploaded,
        createdAt: DateTime.now(),
        sender: me,
        replyToId: replyToId,
        replyTo: replyTo,
        pending: true,
      );
      messagesByChat.putIfAbsent(chatId, () => []);
      messagesByChat[chatId] = [...messagesByChat[chatId]!, optimistic];
      notifyListeners();

      _rt.sendMessage(
        conversationId: chatId,
        body: body,
        kind: kind,
        clientId: clientId,
        mediaUrl: first.mediaUrl,
        mimeType: first.mimeType,
        fileName: first.fileName,
        fileSize: first.fileSize,
        replyToId: replyToId,
        replyQuote: replyQuote,
        attachments: uploaded.map((e) => e.toJson()).toList(),
      );
    } catch (e) {
      error = _friendlyError(e);
    } finally {
      uploading = false;
      notifyListeners();
    }
  }

  void toggleReaction(String messageId, String emoji) {
    if (user == null) return;
    _rt.toggleReaction(messageId: messageId, emoji: emoji);
  }

  void _replaceMessage(ChatMessage message) {
    final chatId = message.conversationId;
    if (!historyLoaded.contains(chatId)) {
      // Don't invent a one-message cache for chats we haven't loaded.
      final pending = _pendingWsMessages.putIfAbsent(chatId, () => []);
      final idx = pending.indexWhere((m) => m.id == message.id);
      if (idx >= 0) {
        pending[idx] = message;
      } else {
        pending.add(message);
      }
      if (activeConversationId == chatId || _historyLoading.contains(chatId)) {
        unawaited(ensureHistory(chatId).catchError((_) {}));
      }
      return;
    }
    final list = List<ChatMessage>.from(messagesByChat[chatId] ?? []);
    final idx = list.indexWhere((m) => m.id == message.id);
    if (idx >= 0) {
      list[idx] = message;
    } else {
      list.add(message);
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    messagesByChat[chatId] = list;
    notifyListeners();
  }

  void notifyTyping() {
    final chatId = activeConversationId;
    if (chatId == null) return;
    _typingThrottle(() => _rt.typing(chatId));
  }

  Future<void> startCall({
    required String mode,
    PrivetUser? peer,
    MediaStream? displayStream,
    MediaStream? localStream,
  }) async {
    final chatId = activeConversationId;
    final me = user;
    if (chatId == null || me == null) {
      await _discardPendingDisplay(displayStream);
      await _discardPendingLocal(localStream);
      return;
    }
    if (callSession != null || ringing != null) {
      error = 'Already in a call';
      await _discardPendingDisplay(displayStream);
      await _discardPendingLocal(localStream);
      notifyListeners();
      return;
    }

    Conversation? chat;
    for (final c in conversations) {
      if (c.id == chatId) chat = c;
    }
    PrivetUser? target = peer ?? chat?.peer;
    if (target == null) {
      error = 'Pick someone to call';
      await _discardPendingDisplay(displayStream);
      await _discardPendingLocal(localStream);
      notifyListeners();
      return;
    }
    if (target.id == me.id) {
      await _discardPendingDisplay(displayStream);
      await _discardPendingLocal(localStream);
      return;
    }

    await _discardPendingDisplay(_pendingDisplayStream);
    await _discardPendingLocal(_pendingLocalStream);
    _pendingDisplayStream = displayStream;
    _pendingLocalStream = localStream;
    _cancelOutgoingWhenRinging = false;

    // Show outgoing UI immediately after Allow — don't wait on WS round-trip
    // (that gap felt like a freeze with the camera already on).
    ringing = ActiveCall(
      call: CallInfo(
        id: 'pending',
        conversationId: chatId,
        mode: mode,
        fromUserId: me.id,
        toUserId: target.id,
      ),
      phase: CallPhase.outgoing,
      peer: target,
      isCaller: true,
      withVideo: mode != 'audio',
    );
    callMinimized = false;
    playOutgoingCallSound();
    notifyListeners();
    wakeUiAfterMediaDialog();

    _rt.inviteCall(conversationId: chatId, toUserId: target.id, mode: mode);
  }

  Future<void> _discardPendingDisplay([MediaStream? stream]) async {
    final s = stream ?? _pendingDisplayStream;
    if (identical(s, _pendingDisplayStream)) {
      _pendingDisplayStream = null;
    }
    if (s == null) return;
    for (final t in s.getTracks()) {
      await t.stop();
    }
    await s.dispose();
    await stopDisplayCaptureService();
  }

  Future<void> _discardPendingLocal([MediaStream? stream]) async {
    final s = stream ?? _pendingLocalStream;
    if (identical(s, _pendingLocalStream)) {
      _pendingLocalStream = null;
    }
    if (s == null) return;
    for (final t in s.getTracks()) {
      await t.stop();
    }
    await s.dispose();
  }

  /// Take ownership of the click-time mic/camera stream (caller path).
  MediaStream? _takePendingLocal() {
    final s = _pendingLocalStream;
    _pendingLocalStream = null;
    return s;
  }

  Future<void> acceptIncoming({bool withVideo = true}) async {
    final incoming = ringing;
    final me = user;
    if (incoming == null || me == null) return;
    // Stop ring the instant Accept is pressed — before any await.
    suppressCallTones();

    // Open mic/camera BEFORE signaling accept. If the user denies, stay on
    // the incoming UI — never hang up a call that was never accepted.
    MediaStream? preparedLocal;
    final mode = incoming.call.mode;
    if (mode != 'screen') {
      // Video invites can be answered with camera or audio-only (asymmetric).
      final withCam = mode == 'video' && withVideo;
      try {
        preparedLocal = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': withCam,
        });
      } catch (e) {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          preparedLocal = await navigator.mediaDevices.getUserMedia({
            'audio': true,
            'video': withCam,
          });
        } catch (e2) {
          if (withCam) {
            // Camera may be exclusively held by another app/browser tab
            // (one physical webcam can't be opened twice on Linux/V4L2).
            // Join with audio only — the camera can be retried from the
            // call screen once it's free.
            try {
              preparedLocal = await navigator.mediaDevices.getUserMedia({
                'audio': true,
                'video': false,
              });
            } catch (e3) {
              error =
                  'Camera/microphone permission is required. Allow access and tap Accept again. ($e3)';
              allowCallTones();
              notifyListeners();
              return;
            }
          } else {
            error =
                'Microphone permission is required. Allow access and tap Accept again. ($e2)';
            allowCallTones();
            notifyListeners();
            return;
          }
        }
      }
      wakeUiAfterMediaDialog();
    }

    ringing = null;
    notifyListeners();
    wakeUiAfterMediaDialog();
    _rt.acceptCall(incoming.call.id);
    await _beginSession(
      call: incoming.call,
      peer: incoming.peer,
      isCaller: false,
      preparedLocal: preparedLocal,
      wantLocalVideo: mode == 'video' && withVideo,
    );
  }

  void rejectIncoming() {
    final incoming = ringing;
    if (incoming == null) return;
    stopAllCallSounds();
    allowCallTones();
    _rt.rejectCall(incoming.call.id);
    ringing = null;
    callMinimized = false;
    notifyCall();
  }

  Future<void> endCall({bool local = false}) async {
    final session = callSession;
    final ring = ringing;
    stopAllCallSounds();
    allowCallTones();
    if (session != null) {
      _rt.hangupCall(session.call.id, toUserId: session.peerId);
      await session.disposeSession();
      callSession = null;
    }
    if (ring != null && local) {
      if (ring.call.id == 'pending') {
        // Invite may still be in flight — reject the real id when it arrives.
        _cancelOutgoingWhenRinging = true;
      } else {
        _rt.rejectCall(ring.call.id);
      }
      ringing = null;
    }
    callMinimized = false;
    resetMiniCallLayout();
    await _discardPendingLocal();
    await _discardPendingDisplay();
    notifyListeners();
  }

  Future<void> _beginSession({
    required CallInfo call,
    required PrivetUser peer,
    required bool isCaller,
    MediaStream? preparedLocal,
    bool? wantLocalVideo,
  }) async {
    final me = user;
    // Caller: use the stream opened on the video/audio icon click.
    final local = preparedLocal ?? (isCaller ? _takePendingLocal() : null);
    if (me == null) {
      if (local != null) {
        for (final t in local.getTracks()) {
          await t.stop();
        }
        await local.dispose();
      }
      return;
    }
    // Connected — never allow ring/ringback to restart for this call.
    suppressCallTones();
    final prepared = isCaller ? _pendingDisplayStream : null;
    if (isCaller) _pendingDisplayStream = null;
    if (prepared != null) {
      await stripDisplayAudioTracks(prepared);
    }
    // Prefer explicit choice; otherwise infer from prepared stream / mode.
    final sendVideo =
        wantLocalVideo ??
        (call.mode == 'video' &&
            (local?.getVideoTracks().isNotEmpty == true || local == null));
    final session = CallSession(
      rt: _rt,
      api: _api,
      selfId: me.id,
      call: call,
      peer: peer,
      isCaller: isCaller,
      preparedDisplay: prepared,
      preparedLocal: local,
      wantLocalVideo: sendVideo,
    );
    callSession = session;
    session.addListener(notifyCall);
    notifyListeners();
    try {
      await session.init();
      if (!session.ready) {
        throw StateError(session.error ?? 'Media not ready');
      }
      // Drop session if hangup raced during init.
      if (!identical(callSession, session)) return;
      suppressCallTones();
      // Keep the newly connected media view mounted. Auto-minimizing a screen
      // call remounted RTCVideoView immediately after its first frame; mobile
      // and PWA renderers often kept the old camera frame or froze white.
      // The presenter can still minimize explicitly after verifying the share.
      callMinimized = false;
      // Skip connect beep while sharing — it can feed into tab/system capture.
      if (!session.isSharingLocally) {
        playCallConnectedSound();
      }
      notifyListeners();
    } catch (e) {
      error = 'Could not start media: $e';
      _rt.hangupCall(call.id, toUserId: peer.id);
      await session.disposeSession();
      if (identical(callSession, session)) {
        callSession = null;
      }
      callMinimized = false;
      allowCallTones();
      notifyListeners();
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'presence':
        online
          ..clear()
          ..addAll(((event['online'] as List?) ?? []).cast<String>());
        _mergeLastSeen(event['lastSeen']);
        notifyInbox();
      case 'conversation.upsert':
        refreshInbox();
      case 'conversation.removed':
        final removedId = event['conversationId'] as String?;
        if (removedId != null) {
          _clearChatCache(removedId);
          if (activeConversationId == removedId) {
            activeConversationId = null;
          }
          refreshInbox();
        }
      case 'members.changed':
        refreshInbox();
      case 'tasks.updated':
        final taskChatId = event['conversationId'] as String?;
        if (taskChatId != null) {
          final raw = (event['items'] as List?) ?? const [];
          tasksByChat[taskChatId] = raw
              .map((e) => TaskItem.fromJson(e as Map<String, dynamic>))
              .toList();
          notifyListeners();
        }
      case 'message':
        final message = ChatMessage.fromJson(
          event['message'] as Map<String, dynamic>,
        );
        final clientId = event['clientId'] as String?;
        final chatId = message.conversationId;
        var isNew = true;
        if (!historyLoaded.contains(chatId)) {
          final pending = _pendingWsMessages.putIfAbsent(chatId, () => []);
          if (clientId != null) {
            pending.removeWhere((m) => m.id == clientId);
          }
          isNew = !pending.any((m) => m.id == message.id);
          if (isNew) pending.add(message);
          // Keep optimistic local rows (active send) in sync without marking loaded.
          if (messagesByChat.containsKey(chatId)) {
            final list = List<ChatMessage>.from(messagesByChat[chatId]!);
            if (clientId != null) {
              list.removeWhere((m) => m.id == clientId);
            }
            if (!list.any((m) => m.id == message.id)) {
              list.add(message);
              list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
            }
            messagesByChat[chatId] = list;
          }
          // Only fetch history if this chat is open / already loading — never
          // invent a one-message cache for background chats.
          if (activeConversationId == chatId ||
              _historyLoading.contains(chatId)) {
            unawaited(ensureHistory(chatId).catchError((_) {}));
          }
        } else {
          final list = List<ChatMessage>.from(messagesByChat[chatId] ?? []);
          if (clientId != null) {
            list.removeWhere((m) => m.id == clientId);
          }
          isNew = !list.any((m) => m.id == message.id);
          if (isNew) {
            list.add(message);
          }
          messagesByChat[chatId] = list;
        }
        final active = activeConversationId == chatId;
        final fromSelf = message.sender.id == user?.id;
        final viewingHere =
            active && chatSurfaceMounted && !documentHidden && documentHasFocus;
        if (!fromSelf) {
          if (viewingHere && _userRecentlyPresent) {
            final idx = conversations.indexWhere((c) => c.id == chatId);
            if (idx >= 0) {
              conversations[idx] = conversations[idx].copyWith(
                unreadCount: 0,
                lastMessage: message,
              );
            }
          } else {
            final idx = conversations.indexWhere((c) => c.id == chatId);
            if (idx >= 0) {
              final c = conversations[idx];
              conversations[idx] = c.copyWith(
                unreadCount: c.unreadCount + 1,
                lastMessage: message,
              );
            }
          }
          // Always ding on every new incoming message (mute is the only off switch).
          // Server sets playSound:false on non-primary sockets so multi-tab /
          // multi-browser logins for the same user only ding once.
          if (isNew && event['playSound'] != false) {
            var muted = false;
            for (final c in conversations) {
              if (c.id == chatId) {
                muted = c.muted;
                break;
              }
            }
            if (!muted && soundEnabled) {
              playMessageSound(messageId: message.id);
            }
          }
        } else {
          final idx = conversations.indexWhere((c) => c.id == chatId);
          if (idx >= 0) {
            conversations[idx] =
                conversations[idx].copyWith(lastMessage: message);
          }
        }
        // Promote the chat without a full HTTP inbox refetch.
        final existingIdx = conversations.indexWhere((c) => c.id == chatId);
        if (existingIdx < 0) {
          _scheduleInboxReconcile();
        } else if (existingIdx > 0) {
          final updated = conversations.removeAt(existingIdx);
          conversations.insert(0, updated);
        }
        notifyChatAndInbox();
        if (viewingHere && _userRecentlyPresent && !fromSelf) {
          _scheduleFocusedRead();
        }
      case 'message.updated':
        final updated = ChatMessage.fromJson(
          event['message'] as Map<String, dynamic>,
        );
        _replaceMessage(updated);
      case 'conversation.read':
        final chatId = event['conversationId'] as String?;
        final readerId = event['userId'] as String?;
        final readAtRaw = event['lastReadAt'] as String?;
        final readMsgId = event['lastReadMessageId'] as String?;
        if (chatId == null || readerId == null) return;
        final readAt = readAtRaw == null
            ? null
            : DateTime.tryParse(readAtRaw.replaceFirst(' ', 'T'));
        final idx = conversations.indexWhere((c) => c.id == chatId);
        if (idx < 0) return;
        final c = conversations[idx];
        if (readerId == user?.id) {
          conversations[idx] = c.copyWith(
            unreadCount: 0,
            lastReadAt: readAt ?? c.lastReadAt,
          );
        } else if (!c.isGroup) {
          conversations[idx] = c.copyWith(
            peerLastReadAt: readAt ?? c.peerLastReadAt,
          );
        } else {
          final reads = List<MemberRead>.from(c.memberReads);
          final rIdx = reads.indexWhere((r) => r.userId == readerId);
          final next = MemberRead(
            userId: readerId,
            lastReadAt: readAt,
            lastReadMessageId: readMsgId,
          );
          if (rIdx >= 0) {
            reads[rIdx] = next;
          } else {
            reads.add(next);
          }
          conversations[idx] = c.copyWith(memberReads: reads);
        }
        notifyListeners();
      case 'notify':
        final chatId = event['conversationId'] as String?;
        if (chatId == null) return;
        var isMuted = false;
        for (final c in conversations) {
          if (c.id == chatId) {
            isMuted = c.muted;
            break;
          }
        }
        if (isMuted || !notificationsEnabled) return;
        // Sound plays on the `message` event (every incoming). Notify is
        // OS toast only — no focus/viewing gates.
        showWebNotification(
          title: (event['title'] as String?) ?? 'Privet',
          body: (event['body'] as String?) ?? 'New message',
          tag: chatId,
          onClick: () => openConversation(chatId),
        );
      case 'typing':
        if (event['conversationId'] == activeConversationId &&
            event['userId'] != user?.id) {
          typingUserId = event['userId'] as String;
          notifyTypingOnly();
          Future.delayed(const Duration(seconds: 2), () {
            if (typingUserId == event['userId']) {
              typingUserId = null;
              notifyTypingOnly();
            }
          });
        }
      case 'auth.ok':
        online
          ..clear()
          ..addAll(((event['online'] as List?) ?? []).cast<String>());
        _mergeLastSeen(event['lastSeen']);
        notifyListeners();
      case 'call.ringing':
        final call = CallInfo.fromJson(event['call'] as Map<String, dynamic>);
        if (_cancelOutgoingWhenRinging) {
          _cancelOutgoingWhenRinging = false;
          _rt.rejectCall(call.id);
          unawaited(_discardPendingLocal());
          unawaited(_discardPendingDisplay());
          ringing = null;
          notifyListeners();
          return;
        }
        PrivetUser? peer = ringing?.isCaller == true ? ringing!.peer : null;
        for (final u in directory) {
          if (u.id == call.toUserId) peer = u;
        }
        peer ??= PrivetUser(
          id: call.toUserId,
          handle: '',
          displayName: 'Peer',
          avatarHue: 160,
        );
        final alreadyOutgoing = ringing?.isCaller == true;
        ringing = ActiveCall(
          call: call,
          phase: CallPhase.outgoing,
          peer: peer,
          isCaller: true,
          withVideo: call.mode != 'audio',
        );
        callMinimized = false;
        // Skip restart when we already started tone in startCall.
        // Display capture strips audio tracks, so classical ringback won't
        // leak into the shared stream after accept (suppressCallTones stops it).
        if (!alreadyOutgoing) {
          playOutgoingCallSound();
        }
        notifyListeners();
      case 'call.incoming':
        final call = CallInfo.fromJson(event['call'] as Map<String, dynamic>);
        final from = PrivetUser.fromJson(event['from'] as Map<String, dynamic>);
        ringing = ActiveCall(
          call: call,
          phase: CallPhase.incoming,
          peer: from,
          isCaller: false,
          withVideo: call.mode != 'audio', // video | screen show as media call
        );
        callMinimized = false;
        startIncomingCallSound();
        notifyListeners();
      case 'call.accepted':
        final callId = event['callId'] as String?;
        final ring = ringing;
        // Both sides get this — hard-stop ring/ringback immediately.
        suppressCallTones();
        if (ring != null &&
            ring.isCaller &&
            (callId == null || ring.call.id == callId)) {
          ringing = null;
          notifyListeners();
          // Reuse mic/camera opened on the call-icon click — no second prompt.
          final local = _takePendingLocal();
          unawaited(
            _beginSession(
              call: ring.call,
              peer: ring.peer,
              isCaller: true,
              preparedLocal: local,
            ),
          );
        } else if (ring != null &&
            !ring.isCaller &&
            (callId == null || ring.call.id == callId)) {
          // Callee: session is started from acceptIncoming; only clear ring UI
          // if the session is already up (accept raced with this event).
          if (callSession != null) {
            ringing = null;
            notifyListeners();
          }
        } else if (ring != null && ring.isCaller) {
          ringing = null;
          notifyListeners();
        }
      case 'call.share_stopped':
        final callId = event['callId'] as String?;
        final session = callSession;
        if (session == null) return;
        if (callId != null && callId != session.call.id) return;
        session.clearRemoteShare();
        notifyListeners();
      case 'call.share_started':
        final callId = event['callId'] as String?;
        final session = callSession;
        if (session == null) return;
        if (callId != null && callId != session.call.id) return;
        session.remoteShareStopped = false;
        session.peerSharingScreen = true;
        session.peerShareControllable = event['controllable'] == true;
        session.peerShareControlPlatform =
            (event['controlPlatform'] as String?)?.trim() ?? '';
        session.peerShareControlBackend =
            (event['controlBackend'] as String?)?.trim() ?? '';
        session.peerShareControlDetail =
            (event['controlDetail'] as String?)?.trim() ?? '';
        session.notifyListeners();
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!identical(callSession, session)) return;
          session.rebindRenderers();
          wakeUiAfterMediaDialog();
        });
        notifyListeners();
      case 'call.control_request':
        final callId = event['callId'] as String?;
        final session = callSession;
        if (session == null) return;
        if (callId != null && callId != session.call.id) return;
        session.remoteControl?.onPeerRequest();
        notifyListeners();
      case 'call.control_grant':
        final callId = event['callId'] as String?;
        final session = callSession;
        if (session == null) return;
        if (callId != null && callId != session.call.id) return;
        session.remoteControl?.onPeerGrant();
        notifyListeners();
      case 'call.control_deny':
        final callId = event['callId'] as String?;
        final session = callSession;
        if (session == null) return;
        if (callId != null && callId != session.call.id) return;
        session.remoteControl?.onPeerDeny(event['reason'] as String?);
        notifyCall();
      case 'call.control_revoke':
        final callId = event['callId'] as String?;
        final session = callSession;
        if (session == null) return;
        if (callId != null && callId != session.call.id) return;
        unawaited(session.remoteControl?.onPeerRevoke());
        notifyCall();
      case 'call.ended':
        final callId = event['callId'] as String?;
        stopAllCallSounds();
        allowCallTones();
        if (ringing?.call.id == callId) {
          ringing = null;
          unawaited(_discardPendingDisplay());
          unawaited(_discardPendingLocal());
        }
        if (callSession?.call.id == callId) {
          callSession?.disposeSession();
          callSession = null;
        }
        callMinimized = false;
        resetMiniCallLayout();
        notifyListeners();
      case 'call.offer':
        final session = callSession;
        if (session == null) return;
        if (event['callId'] != session.call.id) return;
        suppressCallTones();
        final sdp = event['sdp'] as Map<String, dynamic>?;
        if (sdp != null) session.handleRemoteOffer(sdp);
      case 'call.answer':
        final session = callSession;
        if (session == null) return;
        if (event['callId'] != session.call.id) return;
        suppressCallTones();
        final sdp = event['sdp'] as Map<String, dynamic>?;
        if (sdp != null) session.handleRemoteAnswer(sdp);
      case 'call.ice':
        final session = callSession;
        if (session == null) return;
        if (event['callId'] != session.call.id) return;
        final candidate = event['candidate'] as Map<String, dynamic>?;
        if (candidate != null) session.handleIce(candidate);
    }
  }

  void _onTabVisible() {
    final id = activeConversationId;
    if (id == null || user == null || !chatSurfaceMounted) return;
    if (!_userRecentlyPresent) return;
    final idx = conversations.indexWhere((c) => c.id == id);
    if (idx >= 0 && conversations[idx].unreadCount > 0) {
      conversations[idx] = conversations[idx].copyWith(unreadCount: 0);
      notifyListeners();
    }
    _markRead(id, reason: 'tabVisible');
  }

  void clearActiveConversation() {
    activeConversationId = null;
    typingUserId = null;
    notifyShell();
    notifyChatAndInbox();
  }

  void _mergeLastSeen(dynamic raw) {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final at = DateTime.tryParse('${entry.value}'.replaceFirst(' ', 'T'));
      if (at != null) lastSeen['${entry.key}'] = at;
    }
  }

  @override
  void dispose() {
    _focusedReadTimer?.cancel();
    _inboxReconcileTimer?.cancel();
    _typingThrottle.cancel();
    _disposeVisibility?.call();
    _disposeVisibility = null;
    callSession?.disposeSession();
    _rt.disconnect();
    sessionTick.dispose();
    shellTick.dispose();
    inboxTick.dispose();
    chatTick.dispose();
    typingTick.dispose();
    callTick.dispose();
    super.dispose();
  }
}
