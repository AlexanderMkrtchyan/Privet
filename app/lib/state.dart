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
import 'util/agent_debug_log.dart';
import 'util/ai_turn.dart';
import 'util/display_capture.dart';
import 'util/emoticon_expand.dart';
import 'util/gpu_capability.dart';
import 'util/mobile_push.dart';
import 'util/page_title.dart';
import 'util/page_uri.dart';
import 'util/media_ui_wake.dart';
import 'util/remote_input.dart';
import 'util/server_time.dart';
import 'util/sounds.dart';
import 'util/low_resource.dart';
import 'util/throttle.dart';
import 'util/ui_overlay_pause.dart';
import 'util/recv_media_stream.dart';
import 'util/remote_call_audio.dart';
import 'util/webrtc_safe.dart';
import 'util/desktop_call_window.dart';
import 'util/desktop_launcher_badge.dart';
import 'util/desktop_tray.dart';
import 'util/web_notifications.dart';

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
  /// Mutable: audio-only answer starts false; [retryCamera] flips it true.
  bool wantLocalVideo;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _display;
  /// Video-only wrapper for local screen preview (not the capture stream).
  MediaStream? _localPreview;
  String? _displaySourceId;

  /// Set by [disposeSession] so a hangup racing [init] cannot leave live tracks.
  bool _disposed = false;

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
  bool get isRemoteHostPending =>
      remoteControlIncomingRequest && isSharingLocally;
  RemoteInputCapability? get remoteInputCapability => remoteControl?.capability;
  String? get remoteControlError => remoteControl?.error;

  bool get hasMicTrack => _local?.getAudioTracks().isNotEmpty == true;
  bool get hasCamTrack => _local?.getVideoTracks().isNotEmpty == true;
  bool get isScreenCall => call.mode == 'screen';
  bool get isControlCall => call.mode == 'control';

  /// Screen share or dedicated remote-control session (display-first stage).
  bool get isScreenLike => isScreenCall || isControlCall;

  /// True when this side is the one sending a display surface.
  bool get isSharingLocally => sharingScreen;

  /// True when nobody is sharing and the last share just ended — show the
  /// peer avatar + "Share stopped" placeholder (not a frozen/black frame).
  bool get showShareStopped =>
      !sharingScreen &&
      !peerSharingScreen &&
      !remoteHasVideo &&
      remoteShareStopped;

  /// Share button: unlocked after peer stop even if a mute/unmute race left
  /// [peerSharingScreen] stuck true (that regression blocked take-over).
  bool get canStartScreenShare =>
      !isControlCall && (!peerSharingScreen || remoteShareStopped);

  /// Video/control call where we wanted a camera but have none yet (denied /
  /// busy / answered audio-only / joined without A/V). Tapping the camera
  /// button calls [retryCamera].
  bool get cameraPending =>
      (call.mode == 'video' || isControlCall) &&
      !sharingScreen &&
      !hasCamTrack;

  /// Intentionally joined without camera (can still enable later).
  bool get joinedAudioOnly =>
      (call.mode == 'video' || isControlCall) &&
      !wantLocalVideo &&
      !hasCamTrack;

  Future<void> init() async {
    if (_disposed) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    if (_disposed) {
      await _releaseRenderers();
      return;
    }

    final ice = await api.iceServers();
    if (_disposed) {
      await _releaseRenderers();
      return;
    }
    _pc = await createPeerConnection({
      'iceServers': ice.isEmpty
          ? [
              {'urls': 'stun:stun.l.google.com:19302'},
            ]
          : ice,
      'sdpSemantics': 'unified-plan',
    });
    if (_disposed) {
      await _releasePeerConnection();
      await _releaseRenderers();
      return;
    }

    _pc!.onIceCandidate = (c) {
      if (_disposed || c.candidate == null) return;
      rt.sendIce(callId: call.id, toUserId: peerId, candidate: c.toMap());
    };
    _pc!.onTrack = (event) {
      if (_disposed) return;
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
      onQualityRequested: applyRemoteControlQuality,
      onSwitchDisplay: switchRemoteControlDisplay,
      listDisplays: _listRemoteControlDisplays,
    );
    await remoteControl!.attach(_pc!);

    final isScreen = call.mode == 'screen';
    final isControl = call.mode == 'control';
    // Asymmetric: video-mode invite can still join send-audio / recv-video only.
    final withCamera = call.mode == 'video' && wantLocalVideo;

    if (isControl) {
      // Dedicated remote control: no A/V until the user enables mic/cam.
      // Host (callee) shares display + auto-grants; controller (caller) watches.
      micOn = false;
      camOn = false;
      _local = null;
      localRenderer.srcObject = null;

      if (!isCaller) {
        // Host: prepared display from Allow + picker.
        await _attachPreparedDisplayShare(
          preparedDisplay,
          autoGrantControl: true,
        );
      } else {
        // Controller: recv-only so the host can send screen (and either side
        // can add mic/cam later via renegotiation).
        await _pc!.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
        await _pc!.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
    } else if (isScreen) {
      // Screen share must work with zero mic/camera hardware.
      // Do NOT call getUserMedia first — on Firefox it can end the display
      // capture stream and/or hang the call when no device exists.
      micOn = false;
      _local = null;

      if (isCaller) {
        await _attachPreparedDisplayShare(preparedDisplay);
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
      if (_disposed) {
        await _releaseStream(_local);
        _local = null;
        return;
      }
      // Keep tracks live — some browsers leave them disabled after Allow.
      for (final track in _local!.getTracks()) {
        track.enabled = true;
      }
      // Reflect what we actually got, not what the call mode asked for —
      // camera may have failed (denied/not found/busy) while mic succeeded.
      camOn = withCamera && _local!.getVideoTracks().isNotEmpty;
      localRenderer.srcObject = _local;
      // Local preview must not echo; never disable the shared capture track.
      unawaited(muteLocalRenderer(localRenderer));
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

    if (_disposed) {
      // Hangup won the race after we attached media — release leftovers.
      await _releaseDisplayCapture(announce: false);
      await _releaseStream(_local);
      _local = null;
      await _releasePeerConnection();
      await _releaseRenderers();
      return;
    }

    ready = true;
    notifyListeners();

    // Apply any offer/answer/ICE that arrived while getUserMedia / picker ran.
    await _flushPendingSignaling();

    if (_disposed) return;

    if (isCaller) {
      await _sendOffer();
    }
  }

  /// Attach a display capture as the outbound video track (screen / control host).
  Future<void> _attachPreparedDisplayShare(
    MediaStream? prepared, {
    bool autoGrantControl = false,
  }) async {
    if (_disposed) {
      await _releaseStream(prepared);
      return;
    }
    late final MediaStream display;
    if (prepared != null) {
      display = prepared;
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
    if (_disposed) {
      await _releaseStream(display);
      return;
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
    _displaySourceId = lastDesktopCaptureSourceId;
    sharingScreen = true;
    everSharedLocally = true;
    // Never mirror the capture into our own UI. Also suppress stale peer
    // frames from a previous share on this call.
    _purgeStaleRemoteVideo(markStopped: true);
    try {
      localRenderer.srcObject = null;
    } catch (_) {}
    await _clearLocalPreview();
    _scheduleRendererRebind();
    screenTrack.onEnded = () {
      if (_disposed) return;
      _stopScreenShare();
    };
    await _announceShareStarted();
    final settings = screenTrack.getSettings();
    final gw = (settings['width'] as num?)?.toInt();
    final gh = (settings['height'] as num?)?.toInt();
    if (gw != null && gh != null) {
      await remoteControl?.updateLocalGeometry(gw, gh);
    }
    await applyRemoteControlQuality(
      remoteControl?.quality ?? RemoteControlQuality.balanced,
    );
    await remoteControl?.publishDisplaysNow(activeId: _displaySourceId);
    if (autoGrantControl) {
      // Dedicated control invite: grant immediately (no second Allow).
      await remoteControl?.grantControl();
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
    if (_disposed) return;
    try {
      event.track.enabled = true;

      MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
      } else {
        stream = await createRecvMediaStream('remote-${event.track.id}');
        if (_disposed) {
          await _releaseStream(stream);
          return;
        }
        try {
          await stream.addTrack(event.track);
        } catch (_) {
          if (event.track.kind == 'video') {
            await _tryBindRemoteVideoTrack(
              event.track,
              remoteRenderer.srcObject,
            );
          }
          return;
        }
      }
      if (_disposed) return;

      if (event.track.kind == 'video') {
        if (_blockStaleRemoteVideo) return;
        await _bindRemoteVideoStream(event.track, stream);
        return;
      }

      if (event.track.kind == 'audio') {
        event.track.enabled = true;
        final current = remoteRenderer.srcObject;
        var target = stream;
        if (current != null) {
          final already = current.getAudioTracks().any(
            (t) => t.id == event.track.id,
          );
          if (!already) {
            try {
              await current.addTrack(event.track);
            } catch (_) {
              // Native registry miss — keep Dart-side so UI state stays coherent;
              // WebRTC still plays remote audio via the audio device module.
              try {
                await current.addTrack(event.track, addToNative: false);
              } catch (_) {}
            }
          }
          target = current;
        }
        if (_disposed) return;
        // Web: HTMLAudioElement is built inside the srcObject setter — addTrack
        // alone leaves desktop browsers silent. Native: null↔set thrash
        // re-registers Flutter textures and janks Linux/NVIDIA after calls.
        if (kIsWeb) {
          remoteRenderer.srcObject = null;
          remoteRenderer.srcObject = target;
        } else if (!identical(remoteRenderer.srcObject, target)) {
          remoteRenderer.srcObject = target;
        }
        event.track.onUnMute = () {
          if (_disposed) return;
          unawaited(
            ensureRemoteCallAudioPlaying(remoteRenderer: remoteRenderer),
          );
        };
        await ensureRemoteCallAudioPlaying(remoteRenderer: remoteRenderer);
        if (!_disposed) notifyListeners();
      }
    } catch (e) {
      if (_disposed) return;
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
    if (_disposed) return;
    if (_blockStaleRemoteVideo) return;
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
      if (_disposed) return;
      remoteRenderer.srcObject = stream;
      remoteHasVideo = true;
      // Force unmute/play after video bind — desktop browsers otherwise stay silent.
      if (stream.getAudioTracks().isNotEmpty) {
        unawaited(
          ensureRemoteCallAudioPlaying(remoteRenderer: remoteRenderer),
        );
      }
      // Only dedicated screen/control calls treat any remote video as "peer sharing".
      // Mid-call share on video/audio is gated by call.share_started — marking
      // every camera track as a share locked the receiver's Share button.
      if (call.mode == 'screen' || call.mode == 'control') {
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
    if (_disposed) return;
    track.onEnded = () {
      if (_disposed) return;
      _remoteVideoMuteTimer?.cancel();
      _onRemoteVideoEnded(track);
    };
    // replaceTrack commonly emits a short mute while switching camera→screen.
    // Treat only a sustained mute as ended; otherwise clearing srcObject here
    // leaves mobile/PWA renderers permanently white.
    track.onMute = () {
      if (_disposed) return;
      if (call.mode == 'screen' ||
          call.mode == 'control' ||
          peerSharingScreen) {
        _remoteVideoMuteTimer?.cancel();
        _remoteVideoMuteTimer = Timer(const Duration(milliseconds: 900), () {
          if (_disposed) return;
          if (track.muted == true && !remoteShareStopped) {
            _onRemoteVideoEnded(track);
          }
        });
      }
    };
    track.onUnMute = () {
      if (_disposed) return;
      _remoteVideoMuteTimer?.cancel();
      // Ignore unmute after share stop / while we are presenting.
      if (_blockStaleRemoteVideo) return;
      remoteHasVideo = true;
      _scheduleRendererRebind();
      notifyListeners();
    };
    notifyListeners();
  }

  /// After [call.share_started], the peer's SDP may land slightly later (or
  /// [onTrack] may never re-fire on a reused m-line). Retry the receiving
  /// bind a few times so the Ubuntu viewer actually paints the share.
  Future<void> _recoverIncomingShareVideo() async {
    for (final ms in [0, 150, 400, 900, 1800]) {
      if (ms > 0) {
        await Future<void>.delayed(Duration(milliseconds: ms));
      }
      if (_disposed || remoteShareStopped || !peerSharingScreen) return;
      await _bindReceivingVideoTracks();
      if (remoteHasVideo) {
        _scheduleRendererRebind();
        return;
      }
    }
  }

  /// Peer advertised a new screen share — unlock UI and (re)bind remote video.
  void onPeerShareStarted({
    required bool controllable,
    String controlPlatform = '',
    String controlBackend = '',
    String controlDetail = '',
  }) {
    if (_disposed) return;
    remoteShareStopped = false;
    peerSharingScreen = true;
    peerShareControllable = controllable;
    peerShareControlPlatform = controlPlatform;
    peerShareControlBackend = controlBackend;
    peerShareControlDetail = controlDetail;
    notifyListeners();
    // Never null↔set textures here on Linux — that path crashed mid-handoff.
    // Bind (with retries) is what makes the share visible on native.
    unawaited(_recoverIncomingShareVideo());
    if (kIsWeb) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        rebindRenderers();
        wakeUiAfterMediaDialog();
      });
    } else {
      wakeUiAfterMediaDialog();
    }
  }

  /// Safety net for the screen-share handoff. When the callee takes over
  /// sharing back to the original caller, the caller reuses its old
  /// (previously send-only) transceiver and merely flips it to receiving.
  /// Some engines (notably Chrome via the web wrapper) do NOT re-fire
  /// [onTrack] for that direction change, so the caller would bind nothing and
  /// the peer's new share never appears — exactly the "A can't see B's screen
  /// after B takes over" bug. After every renegotiation, scan the receiving
  /// video transceivers and surface any incoming track [onTrack] missed.
  ///
  /// Same class of bug for "answer audio-only, peer enables camera later":
  /// we stay [SendOnly] until renegotiation, [getCurrentDirection] can lag,
  /// and [onTrack] often never re-fires — so also honor pending [getDirection]
  /// and arm unmute watchers on still-SendOnly receivers.
  Future<void> _bindReceivingVideoTracks() async {
    if (_disposed || _pc == null) return;
    // While we present, or after peer stop without a new share_started, never
    // rebind leftover receiver tracks — that painted their last frame again
    // when we later stopped our own share.
    if (_blockStaleRemoteVideo) return;
    var bound = false;
    try {
      final list = await _pc!.getTransceivers();
      if (_disposed) return;
      for (final t in list) {
        if (_disposed) return;
        if (t.stoped) continue;
        TransceiverDirection? currentDir;
        TransceiverDirection? desiredDir;
        try {
          currentDir = await t.getCurrentDirection();
        } catch (_) {}
        try {
          desiredDir = await t.getDirection();
        } catch (_) {}
        final track = t.receiver.track;
        if (track == null || track.kind != 'video') continue;
        final receiving =
            currentDir == TransceiverDirection.RecvOnly ||
            currentDir == TransceiverDirection.SendRecv ||
            desiredDir == TransceiverDirection.RecvOnly ||
            desiredDir == TransceiverDirection.SendRecv;
        final current = remoteRenderer.srcObject;
        final already =
            current != null &&
            current.getVideoTracks().any((v) => v.id == track.id);
        if (!receiving) {
          // Native often leaves an already-unmuted receiver track on SendOnly;
          // onUnMute will never fire — also watch mute→unmute and frame path.
          _armReceiverUnmuteBind(track);
          continue;
        }
        // Never resurrect a share the peer explicitly stopped.
        if (remoteShareStopped && track.muted == true) {
          _armReceiverUnmuteBind(track);
          continue;
        }
        // Dart MediaStream.addTrack appends locally BEFORE the native call.
        // A failed MediaStreamAddTrack leaves a zombie "already" entry with no
        // GPU frames — drop it and retry a real native bind.
        if (already && !remoteHasVideo && current != null) {
          try {
            await current.removeTrack(track, removeFromNative: false);
          } catch (_) {}
        } else if (already) {
          if (!remoteHasVideo) {
            remoteHasVideo = true;
            bound = true;
            notifyListeners();
          }
          continue;
        }
        final ok = await _tryBindRemoteVideoTrack(
          track,
          remoteRenderer.srcObject,
        );
        if (ok) bound = true;
      }
    } catch (_) {}
    if (bound && !_disposed) {
      // Web reuses one <video> element per renderer; a fresh bind can leave a
      // frozen frame until srcObject is rebound after the frame is laid out.
      // Native texture rebind is expensive — only needed on web DOM remounts.
      if (kIsWeb) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!_disposed) rebindRenderers();
        });
      }
    }
  }

  /// Attach a receiver video track to [remoteRenderer]. Native addTrack can
  /// throw when the track is already owned by an internal stream — fall back
  /// to merging into the existing remote stream.
  Future<bool> _tryBindRemoteVideoTrack(
    MediaStreamTrack track,
    MediaStream? current,
  ) async {
    // Warm Linux flutter_webrtc's track cache (GetTransceivers) before
    // mediaStreamAddTrack — otherwise MediaTrackForId returns null / crashed.
    if (!kIsWeb && _pc != null) {
      try {
        await _pc!.getTransceivers();
      } catch (_) {}
    }

    Future<void> scrubZombie(MediaStream stream) async {
      try {
        if (stream.getVideoTracks().any((v) => v.id == track.id)) {
          await stream.removeTrack(track, removeFromNative: false);
        }
      } catch (_) {}
    }

    // Prefer the existing remote stream so web keeps a non-"local" ownerTag.
    // createLocalMediaStream tags ownerTag=local → HTMLAudioElement muted.
    if (current != null) {
      try {
        await scrubZombie(current);
        if (!current.getVideoTracks().any((v) => v.id == track.id)) {
          await current.addTrack(track);
        }
        await _bindRemoteVideoStream(track, current);
        return true;
      } catch (_) {}
    }
    try {
      final wrapper = await createRecvMediaStream('recv-${track.id}');
      await wrapper.addTrack(track);
      await _bindRemoteVideoStream(track, wrapper);
      return true;
    } catch (_) {}
    try {
      final wrapper = await createRecvMediaStream('recv-fb-${track.id}');
      await wrapper.addTrack(track);
      remoteRenderer.srcObject = wrapper;
      remoteHasVideo = true;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// When a previously send-only m-line starts receiving, [onTrack] may not
  /// re-fire; the receiver track simply unmutes. Re-run the bind scan then.
  void _armReceiverUnmuteBind(MediaStreamTrack track) {
    if (_disposed || track.kind != 'video') return;
    track.onUnMute = () {
      if (_disposed || _blockStaleRemoteVideo) return;
      unawaited(_bindReceivingVideoTracks());
    };
    // Some engines report the placeholder receiver as already unmuted while
    // still SendOnly — also re-scan when mute clears after being muted.
    track.onMute = () {
      if (_disposed) return;
      track.onUnMute = () {
        if (_disposed || _blockStaleRemoteVideo) return;
        unawaited(_bindReceivingVideoTracks());
      };
    };
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
      // Only force recvonly while we still have no camera to send. After
      // [retryCamera], wantLocalVideo/hasCamTrack are true — forcing RecvOnly
      // here would silently kill the just-enabled outbound video on the next
      // remote offer (collision rollback, peer renegotiation, etc.).
      if (call.mode == 'video' && !wantLocalVideo && !hasCamTrack) {
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
      // Receiver tracks from a SendOnly→SendRecv upgrade are often not
      // readable until after the answer is fully applied on both sides.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        unawaited(_bindReceivingVideoTracks());
      });
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
      SchedulerBinding.instance.addPostFrameCallback((_) {
        unawaited(_bindReceivingVideoTracks());
      });
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
    if (!hasMicTrack) {
      await enableMic();
      return;
    }
    micOn = !micOn;
    for (final t in _local?.getAudioTracks() ?? []) {
      t.enabled = micOn;
    }
    // User gesture: retry remote HTML audio play (desktop autoplay).
    unawaited(ensureRemoteCallAudioPlaying(remoteRenderer: remoteRenderer));
    notifyListeners();
  }

  /// Open the microphone mid-session (control / screen sessions start without A/V).
  Future<void> enableMic() async {
    if (_disposed || _pc == null || hasMicTrack) return;
    MediaStream? mic;
    try {
      mic = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
    } catch (e) {
      error = 'Microphone permission is required to talk. ($e)';
      notifyListeners();
      return;
    }
    if (_disposed) {
      await _releaseStream(mic);
      return;
    }
    final tracks = mic.getAudioTracks();
    if (tracks.isEmpty) {
      await _releaseStream(mic);
      error = 'No microphone track available.';
      notifyListeners();
      return;
    }
    final track = tracks.first;
    track.enabled = true;
    _local ??= await createLocalMediaStream('local');
    await _local!.addTrack(track);
    // Same Linux rule as retryCamera: never dispose the getUserMedia wrapper
    // while it still owns the track — that unregisters/stops capture.
    try {
      await mic.removeTrack(track);
    } catch (_) {}
    try {
      if (mic.getTracks().isEmpty) await mic.dispose();
    } catch (_) {}
    // Prefer upgrading an existing recv-only audio transceiver.
    final list = await _pc!.getTransceivers();
    RTCRtpTransceiver? audioT;
    for (final t in list) {
      if (t.stoped) continue;
      try {
        final kind = t.receiver.track?.kind ?? t.sender.track?.kind;
        if (kind == 'audio') {
          audioT = t;
          break;
        }
      } catch (_) {}
    }
    if (audioT != null) {
      try {
        await audioT.setDirection(TransceiverDirection.SendRecv);
      } catch (_) {}
      try {
        await audioT.sender.replaceTrack(track);
      } catch (_) {
        await _pc!.addTrack(track, _local!);
      }
    } else {
      await _pc!.addTrack(track, _local!);
    }
    micOn = true;
    error = null;
    notifyListeners();
    await _renegotiateAfterTrackChange();
  }

  Future<void> toggleCam() async {
    if (sharingScreen || isScreenCall) return;
    if (!hasCamTrack) {
      await retryCamera();
      return;
    }
    camOn = !camOn;
    for (final t in _local?.getVideoTracks() ?? []) {
      t.enabled = camOn;
    }
    notifyListeners();
  }

  /// Re-attempt to open the camera (e.g. once another app/browser tab
  /// releases it) and add it to the running call without restarting anything.
  Future<void> retryCamera() async {
    if (_disposed || sharingScreen || isScreenCall || _pc == null) return;
    if (hasCamTrack) {
      if (!camOn) {
        camOn = true;
        for (final t in _local!.getVideoTracks()) {
          t.enabled = true;
        }
        notifyListeners();
      }
      return;
    }
    MediaStream? cam;
    try {
      cam = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': true,
      });
    } catch (_) {
      cam = await _tryAlternateCamera(audio: false);
    }
    if (_disposed) {
      await _releaseStream(cam);
      return;
    }
    if (cam == null || cam.getVideoTracks().isEmpty) {
      await _releaseStream(cam);
      error =
          'Camera still unavailable — it may be open in another app or browser tab.';
      notifyListeners();
      return;
    }
    final track = cam.getVideoTracks().first;
    track.enabled = true;
    _local ??= await createLocalMediaStream('local');
    await _local!.addTrack(track);
    // Detach from the temporary getUserMedia stream WITHOUT disposing it first.
    // On Linux, MediaStream.dispose() erases the track from the native registry
    // and stops the capturer — then PeerConnection.addTrack fails with
    // "track is null" and replaceTrack sends a dead camera.
    try {
      await cam.removeTrack(track);
    } catch (_) {}
    try {
      if (cam.getTracks().isEmpty) await cam.dispose();
    } catch (_) {}

    // Attach to the peer connection while the track is still registered.
    final transceiver = await _videoTransceiver();
    String? dirBefore;
    if (transceiver != null) {
      try {
        dirBefore = (await transceiver.getCurrentDirection())?.name;
      } catch (_) {}
      // RecvOnly/Inactive → prefer a fresh outbound m-line so the peer gets
      // onTrack (replaceTrack upgrades are unreliable on Linux→Firefox).
      final upgrading =
          dirBefore == 'RecvOnly' ||
          dirBefore == 'Inactive' ||
          dirBefore == null;
      if (upgrading) {
        try {
          _videoSender = await _pc!.addTrack(track, _local!);
          _videoMid = null;
        } catch (_) {
          try {
            await transceiver.setDirection(TransceiverDirection.SendRecv);
          } catch (_) {}
          try {
            await transceiver.sender.replaceTrack(track);
            _videoSender = transceiver.sender;
          } catch (_) {}
        }
      } else {
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
      }
    } else {
      _videoSender = await _pc!.addTrack(track, _local!);
      _videoMid = null;
    }

    localRenderer.srcObject = null;
    localRenderer.srcObject = _local;
    unawaited(muteLocalRenderer(localRenderer));
    _scheduleRendererRebind();
    // We are now sending camera — stop treating later remote offers as
    // audio-only (which forced RecvOnly and killed outbound video).
    wantLocalVideo = true;
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
  Future<void> startScreenShare(
    MediaStream display, {
    String? sourceId,
  }) async {
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
      _displaySourceId = sourceId ?? lastDesktopCaptureSourceId;
      sharingScreen = true;
      everSharedLocally = true;
      // Status-only while sharing — do not paint our own capture locally.
      // Keep remoteShareStopped so peer's leftover receiver track cannot
      // resurrect as a frozen frame when we later stop presenting.
      _purgeStaleRemoteVideo(markStopped: true);
      try {
        localRenderer.srcObject = null;
      } catch (_) {}
      await _clearLocalPreview();
      _scheduleRendererRebind();
      screenTrack.onEnded = () {
        if (_disposed) return;
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
      await applyRemoteControlQuality(
        remoteControl?.quality ?? RemoteControlQuality.balanced,
      );
      await remoteControl?.publishDisplaysNow(activeId: _displaySourceId);
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
      if (call.mode == 'screen' || call.mode == 'control') {
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
    if (_disposed) return;
    // Drop the renderer stream so the UI cannot keep painting a frozen frame.
    final current = remoteRenderer.srcObject;
    if (current != null) {
      final stillLiveVideo = current.getVideoTracks().any(
        (t) => t.id != track.id && t.enabled && t.muted != true,
      );
      if (!stillLiveVideo) {
        // Flags first → placeholder stage, then detach (avoids black Texture).
        remoteHasVideo = false;
        if (call.mode == 'screen' ||
            call.mode == 'control' ||
            peerSharingScreen) {
          remoteShareStopped = true;
          peerSharingScreen = false;
          _clearPeerShareControlMeta();
          unawaited(remoteControl?.onRemoteShareStopped());
        }
        notifyListeners();
        try {
          remoteRenderer.srcObject = null;
        } catch (_) {}
      }
    } else {
      remoteHasVideo = false;
      if (call.mode == 'screen' ||
          call.mode == 'control' ||
          peerSharingScreen) {
        remoteShareStopped = true;
        peerSharingScreen = false;
        _clearPeerShareControlMeta();
        unawaited(remoteControl?.onRemoteShareStopped());
      }
      notifyListeners();
    }
  }

  void clearRemoteShare() {
    _purgeStaleRemoteVideo(markStopped: true);
    unawaited(remoteControl?.onRemoteShareStopped());
  }

  /// Drop remote video UI + disarm unmute/ended handlers so a stopped peer
  /// share cannot resurrect as a frozen last frame after we present/stop.
  void _purgeStaleRemoteVideo({required bool markStopped}) {
    _remoteVideoMuteTimer?.cancel();
    remoteHasVideo = false;
    if (markStopped) {
      remoteShareStopped = true;
      peerSharingScreen = false;
      _clearPeerShareControlMeta();
    }
    notifyListeners();
    try {
      final stream = remoteRenderer.srcObject;
      if (stream != null) {
        for (final t in stream.getTracks()) {
          _clearTrackCallbacks(t);
        }
      }
    } catch (_) {}
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}
  }

  /// True when we must not paint incoming video (we are presenting, or the
  /// peer explicitly stopped and has not started again).
  bool get _blockStaleRemoteVideo =>
      sharingScreen || (remoteShareStopped && !peerSharingScreen);

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

  Future<void> _clearLocalPreview() async {
    final old = _localPreview;
    _localPreview = null;
    if (old == null) return;
    try {
      if (identical(localRenderer.srcObject, old)) {
        localRenderer.srcObject = null;
      }
    } catch (_) {}
    // Don't stop tracks — they belong to [_display] / the sender.
    try {
      await old.dispose();
    } catch (_) {}
  }

  Future<void> _stopScreenShare() async {
    if (_disposed || !sharingScreen) return;
    // Explicit signal — browsers often leave a frozen last frame when the
    // track is merely stopped/replaced, without firing mute/ended to the peer.
    // Do NOT renegotiate here: a stop-offer races the peer's take-over offer
    // (glare) and was breaking "other person can share after stop".
    rt.sendShareStopped(callId: call.id, toUserId: peerId);
    await remoteControl?.onLocalShareStopped();

    final isScreenCall = call.mode == 'screen' || call.mode == 'control';
    final camTrack =
        !isScreenCall && _local?.getVideoTracks().isNotEmpty == true
        ? _local!.getVideoTracks().first
        : null;

    // Drop share UI first — never leave a capture Texture mounted (black /
    // last-frame). Always mark share stopped so both sides show the same
    // neutral placeholder (not "You stopped…" on the wrong peer).
    sharingScreen = false;
    remoteShareStopped = true;
    // Purge again: unmute callbacks from the peer's old track must not
    // rebind their last frame now that we are no longer presenting.
    _purgeStaleRemoteVideo(markStopped: true);
    try {
      localRenderer.srcObject = null;
    } catch (_) {}
    await _clearLocalPreview();
    notifyListeners();

    // Stop sending frames.
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
    // Avoid MediaStream.dispose() on Linux while the PC may still hold refs —
    // stop tracks is enough; drop the Dart handle.
    _display = null;
    _displaySourceId = null;
    try {
      await stopDisplayCaptureService();
    } catch (_) {}
    // Restore camera preview only when this wasn't a screen-only call.
    if (camTrack != null && _local != null) {
      localRenderer.srcObject = _local;
    }
    _scheduleRendererRebind();
    notifyListeners();
  }

  /// Re-attach streams after RTCVideoView remounts (minimize/maximize on web).
  /// flutter_webrtc reuses a fixed video element id per renderer — remounts can
  /// leave a stale DOM node and a frozen frame until srcObject is rebound.
  ///
  /// Native Linux: null↔set thrash re-registers Flutter pixel-buffer textures
  /// and has crashed mid-call (share handoff, PiP, minimize). Skip the detach;
  /// [notifyListeners] is enough for RTCVideoView to pick up existing frames.
  void rebindRenderers() {
    if (_disposed) return;
    if (!kIsWeb) {
      notifyListeners();
      return;
    }
    final local = localRenderer.srcObject;
    final remote = remoteRenderer.srcObject;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    if (local != null) {
      localRenderer.srcObject = local;
      unawaited(muteLocalRenderer(localRenderer));
    }
    if (remote != null) {
      remoteRenderer.srcObject = remote;
      unawaited(ensureRemoteCallAudioPlaying(remoteRenderer: remoteRenderer));
    }
    notifyListeners();
  }

  void _scheduleRendererRebind() {
    if (_disposed) return;
    // Native texture null↔set is expensive on Linux/NVIDIA; web needs it for
    // DOM remounts after minimize/maximize.
    if (!kIsWeb) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
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
    // Hosting: drop the nested local screen preview (capture still sends).
    if (remoteControl?.state.isHost == true) {
      try {
        localRenderer.srcObject = null;
      } catch (_) {}
      _scheduleRendererRebind();
    }
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

  Future<void> setRemoteControlQuality(RemoteControlQuality mode) async {
    await remoteControl?.setQuality(mode);
    notifyListeners();
  }

  Future<void> switchRemoteControlDisplay(String sourceId) async {
    if (!sharingScreen || sourceId.isEmpty) return;
    if (_displaySourceId == sourceId) return;
    try {
      final next = await captureDisplayMedia(
        prefer: DisplayShareSurface.monitor,
        sourceId: sourceId,
      );
      await stripDisplayAudioTracks(next);
      final tracks = next.getVideoTracks();
      if (tracks.isEmpty) {
        for (final t in next.getTracks()) {
          await t.stop();
        }
        await next.dispose();
        return;
      }
      final screenTrack = tracks.first;
      final old = _display;
      final transceiver = await _videoTransceiver();
      if (transceiver != null) {
        await transceiver.sender.replaceTrack(screenTrack);
        _videoSender = transceiver.sender;
      } else if (_videoSender != null) {
        await _videoSender!.replaceTrack(screenTrack);
      } else {
        _videoSender = await _pc!.addTrack(screenTrack, next);
      }
      _display = next;
      _displaySourceId = sourceId;
      // Still no local mirror of the capture — status chrome covers sharing.
      try {
        localRenderer.srcObject = null;
      } catch (_) {}
      await _clearLocalPreview();
      screenTrack.onEnded = () {
        if (_disposed) return;
        _stopScreenShare();
      };
      final settings = screenTrack.getSettings();
      final gw = (settings['width'] as num?)?.toInt();
      final gh = (settings['height'] as num?)?.toInt();
      if (gw != null && gh != null) {
        await remoteControl?.updateLocalGeometry(gw, gh);
      }
      await applyRemoteControlQuality(
        remoteControl?.quality ?? RemoteControlQuality.balanced,
      );
      await remoteControl?.publishDisplaysNow(activeId: sourceId);
      if (old != null) {
        for (final t in old.getTracks()) {
          try {
            await t.stop();
          } catch (_) {}
        }
        try {
          await old.dispose();
        } catch (_) {}
      }
      _scheduleRendererRebind();
      notifyListeners();
    } catch (e) {
      error = 'Could not switch display: $e';
      notifyListeners();
    }
  }

  Future<List<RemoteDisplayInfo>> _listRemoteControlDisplays() async {
    final sources = await listDesktopScreens();
    return [
      for (final s in sources)
        RemoteDisplayInfo(
          id: s.id,
          name: s.name.isNotEmpty ? s.name : 'Display',
        ),
    ];
  }

  Future<void> applyRemoteControlQuality(RemoteControlQuality mode) async {
    final track = _display?.getVideoTracks().isNotEmpty == true
        ? _display!.getVideoTracks().first
        : _videoSender?.track;
    if (track == null || track.kind != 'video') return;

    final int maxW;
    final int maxH;
    final double maxFps;
    final int maxBitrate;
    final double scaleDown;
    switch (mode) {
      case RemoteControlQuality.quality:
        maxW = 2560;
        maxH = 1440;
        maxFps = 60;
        maxBitrate = 10 * 1000 * 1000;
        scaleDown = 1.0;
      case RemoteControlQuality.balanced:
        maxW = 1600;
        maxH = 900;
        maxFps = 30;
        maxBitrate = 3 * 1000 * 1000;
        scaleDown = 1.25;
      case RemoteControlQuality.speed:
        maxW = 960;
        maxH = 540;
        maxFps = 20;
        maxBitrate = 900 * 1000;
        scaleDown = 2.0;
    }

    try {
      await track.applyConstraints({
        'width': {'ideal': maxW, 'max': maxW},
        'height': {'ideal': maxH, 'max': maxH},
        'frameRate': {'ideal': maxFps, 'max': maxFps},
      });
    } catch (_) {}

    final sender = _videoSender;
    if (sender == null) return;
    try {
      final params = sender.parameters;
      var encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        encodings = [RTCRtpEncoding()];
        params.encodings = encodings;
      }
      for (final e in encodings) {
        e.active = true;
        e.maxBitrate = maxBitrate;
        e.maxFramerate = maxFps.round();
        // Desktop capturers often ignore applyConstraints — scaling the
        // encoded stream is what actually changes Balanced / Speed.
        e.scaleResolutionDownBy = scaleDown;
      }
      // Prefer sharpness in Quality; allow fps tradeoff in Speed.
      params.degradationPreference = mode == RemoteControlQuality.quality
          ? RTCDegradationPreference.MAINTAIN_RESOLUTION
          : mode == RemoteControlQuality.speed
              ? RTCDegradationPreference.MAINTAIN_FRAMERATE
              : RTCDegradationPreference.BALANCED;
      await sender.setParameters(params);
    } catch (e) {
      debugPrint('applyRemoteControlQuality setParameters failed: $e');
    }
  }

  Future<void> disposeSession() async {
    if (_disposed) return;
    _disposed = true;
    // #region agent log
    agentDebugLog(
      hypothesisId: 'H4',
      location: 'state.dart:disposeSession',
      message: 'disposeSession begin',
      data: {'callId': call.id, 'mode': call.mode, 'native': !kIsWeb},
    );
    final disposeSw = Stopwatch()..start();
    void step(String name) {
      agentDebugLog(
        hypothesisId: 'H4',
        location: 'state.dart:disposeSession',
        message: 'dispose step',
        data: {
          'callId': call.id,
          'step': name,
          'elapsedMs': disposeSw.elapsedMilliseconds,
        },
      );
    }
    // #endregion
    ready = false;
    _remoteVideoMuteTimer?.cancel();
    _remoteVideoMuteTimer = null;
    micOn = false;
    camOn = false;
    sharingScreen = false;
    remoteHasVideo = false;

    final pc = _pc;
    _pc = null;
    _videoSender = null;
    _videoMid = null;
    final ownedDisplay = _display;
    _display = null;
    _displaySourceId = null;
    final ownedLocal = _local;
    _local = null;
    final ownedPreview = _localPreview;
    _localPreview = null;

    // 1) Kill async callbacks so nothing re-enters during teardown.
    if (pc != null) {
      try {
        pc.onTrack = null;
      } catch (_) {}
      try {
        pc.onIceCandidate = null;
      } catch (_) {}
      try {
        pc.onDataChannel = null;
      } catch (_) {}
    }
    for (final t in ownedDisplay?.getTracks() ?? const <MediaStreamTrack>[]) {
      _clearTrackCallbacks(t);
    }
    for (final t in ownedLocal?.getTracks() ?? const <MediaStreamTrack>[]) {
      _clearTrackCallbacks(t);
    }
    step('callbacks');

    try {
      await remoteControl?.dispose();
    } catch (_) {}
    remoteControl = null;
    step('remoteControl');

    // 2) Detach GPU textures from tracks, then dispose renderers BEFORE
    // closing the PC. Reverse order left OnFrame → MarkTextureFrameAvailable
    // hitting a half-dead registrar ("corrupted size vs. prev_size").
    try {
      localRenderer.srcObject = null;
    } catch (_) {}
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}
    step('srcObject-null');

    try {
      await localRenderer.dispose();
    } catch (_) {}
    try {
      await remoteRenderer.dispose();
    } catch (_) {}
    step('renderers');

    // 3) Close PeerConnection (releases sender/receiver track refs).
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
      // Skip pc.dispose() on native — close() is enough and dispose() raced
      // capturer cleanup into heap corruption on End call.
      if (kIsWeb) {
        try {
          await pc.dispose();
        } catch (_) {}
      }
    }
    step('pc');

    // 4) Stop owned tracks. Do NOT MediaStream.dispose() on native — that
    // erases the capturer registry and double-frees with PC teardown.
    Future<void> stopTracks(MediaStream? stream) async {
      if (stream == null) return;
      for (final t in stream.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      if (kIsWeb) {
        try {
          await stream.dispose();
        } catch (_) {}
      }
    }

    await stopTracks(ownedPreview);
    await stopTracks(ownedDisplay);
    try {
      await stopDisplayCaptureService();
    } catch (_) {}
    await stopTracks(ownedLocal);
    await stopTracks(preparedLocal);
    await stopTracks(preparedDisplay);
    step('tracks');

    // #region agent log
    agentDebugSetHasCall(false);
    agentDebugLog(
      hypothesisId: 'H4',
      location: 'state.dart:disposeSession',
      message: 'disposeSession end',
      data: {
        'callId': call.id,
        'elapsedMs': disposeSw.elapsedMilliseconds,
      },
    );
    // #endregion
  }

  static void _clearTrackCallbacks(MediaStreamTrack? track) {
    if (track == null) return;
    try {
      track.onMute = null;
    } catch (_) {}
    try {
      track.onUnMute = null;
    } catch (_) {}
    try {
      track.onEnded = null;
    } catch (_) {}
  }

  Future<void> _releaseDisplayCapture({required bool announce}) async {
    if (_display == null && !sharingScreen) return;
    // Clear before stop() so track.onEnded cannot re-enter [_stopScreenShare].
    final wasSharing = sharingScreen;
    sharingScreen = false;
    if (announce && wasSharing) {
      try {
        rt.sendShareStopped(callId: call.id, toUserId: peerId);
      } catch (_) {}
      try {
        await remoteControl?.onLocalShareStopped();
      } catch (_) {}
    }
    final display = _display;
    _display = null;
    if (display != null) {
      for (final t in display.getTracks()) {
        try {
          t.onEnded = null;
        } catch (_) {}
        try {
          t.enabled = false;
        } catch (_) {}
        try {
          await t.stop();
        } catch (_) {}
      }
      // Native: skip MediaStream.dispose — registry erase races PC teardown.
      if (kIsWeb) {
        try {
          await display.dispose();
        } catch (_) {}
      }
    }
    try {
      await stopDisplayCaptureService();
    } catch (_) {}
  }

  Future<void> _releasePeerConnection() async {
    final pc = _pc;
    _pc = null;
    _videoSender = null;
    _videoMid = null;
    if (pc == null) return;
    try {
      await pc.close();
    } catch (_) {}
    try {
      await pc.dispose();
    } catch (_) {}
  }

  Future<void> _releaseRenderers() async {
    try {
      localRenderer.srcObject = null;
    } catch (_) {}
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}
    try {
      await localRenderer.dispose();
    } catch (_) {}
    try {
      await remoteRenderer.dispose();
    } catch (_) {}
  }

  static Future<void> _stopTrack(MediaStreamTrack track) async {
    try {
      await track.stop();
    } catch (_) {}
  }

  static Future<void> _releaseStream(MediaStream? stream) async {
    if (stream == null) return;
    for (final t in stream.getTracks()) {
      await _stopTrack(t);
    }
    try {
      await stream.dispose();
    } catch (_) {}
  }
}

class PrivetState extends ChangeNotifier {
  PrivetState() {
    _api = ApiClient();
    _rt = RealtimeClient(url: _api.wsUrl);
    _rt.addHandler(_onEvent);
    _disposeVisibility = onDocumentVisible(_onTabVisible);
    // Install focus hooks early (web document focus / desktop window focus).
    documentHasFocus;
  }

  late final ApiClient _api;
  late final RealtimeClient _rt;
  final _uuid = const Uuid();
  void Function()? _disposeVisibility;
  Timer? _focusedReadTimer;
  Timer? _inboxReconcileTimer;
  SharedPreferences? _prefsCache;
  /// Keep under the peer clear window and above the server rate limit so
  /// refreshes are not dropped (matched 2s/2s used to lag ~3–4s).
  final _typingThrottle = Throttle(const Duration(milliseconds: 800));
  String? _typingThrottleChatId;
  /// conversationId:userId → when we last applied a message from that peer.
  /// Used to drop late typing pulses that race after their send.
  final Map<String, DateTime> _lastPeerMessageAt = {};
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
  final Map<String, List<TaskItem>> taskHistoryByChat = {};
  final Map<String, bool> taskHistoryHasMoreByChat = {};
  final Set<String> taskHistoryLoadingOlder = {};
  static const int taskHistoryPageSize = 20;
  final Map<String, List<PaymentReminder>> remindersByChat = {};
  final Map<String, List<PaymentReminder>> reminderHistoryByChat = {};
  final Set<String> online = {};
  final Map<String, DateTime> lastSeen = {};
  List<PrivetUser> blocked = [];
  String? activeConversationId;
  /// Active-chat typer (convenience mirror of [typingByChat]).
  String? typingUserId;
  /// conversationId → userId currently typing (for inbox + chat chrome).
  final Map<String, String> typingByChat = {};
  final Map<String, Timer> _typingClearTimers = {};
  String? error;
  bool booting = true;
  bool busy = false;
  bool uploading = false;

  /// Contacts allowed to control this host without an Allow dialog while the
  /// app stays open (cleared on logout).
  final Set<String> autoAllowControlUserIds = {};

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

  /// Prefer lower RAM/CPU: static emoji, no UI motion, capped image decode.
  /// Manual Profile toggle, or one-shot GPU probe when preference is unset.
  /// Capable GPUs (e.g. RTX) stay animated; software GL gets cheap mode.
  bool lowResourceMode = false;

  /// Legacy toast flag (auto-detect removed; kept so old builds don't break).
  bool lowResourceAutoHint = false;

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
    // Remounting RTCVideoView (mini ↔ full) needs a post-frame srcObject rebind
    // or the camera/remote video stays on a frozen/black frame — web and native.
    final session = callSession;
    if (session == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!identical(callSession, session)) return;
      session.rebindRenderers();
      wakeUiAfterMediaDialog();
    });
  }

  bool shouldAutoAllowControl(String userId) =>
      autoAllowControlUserIds.contains(userId);

  void rememberAutoAllowControl(String userId) {
    if (userId.isEmpty) return;
    if (autoAllowControlUserIds.add(userId)) notifyListeners();
  }

  void forgetAutoAllowControl(String userId) {
    if (autoAllowControlUserIds.remove(userId)) notifyListeners();
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

  bool _pauseInbox = false;
  bool _pauseChat = false;
  bool _pauseShell = false;
  bool _overlayResumeArmed = false;

  void _armOverlayResume() {
    if (_overlayResumeArmed) return;
    _overlayResumeArmed = true;
    UiOverlayPause.afterResume(() {
      _overlayResumeArmed = false;
      _flushOverlayPauses();
    });
  }

  void _flushOverlayPauses() {
    if (_pauseShell) {
      _pauseShell = false;
      _bump(shellTick);
    }
    if (_pauseInbox) {
      _pauseInbox = false;
      _bump(inboxTick);
      _syncDesktopTrayUnread();
    }
    if (_pauseChat) {
      _pauseChat = false;
      _bump(chatTick);
    }
  }

  int get totalUnreadCount {
    var n = 0;
    for (final c in conversations) {
      n += c.unreadCount;
    }
    return n;
  }

  /// Linux / Windows tray + Ubuntu dock badge from the same unread total.
  void _syncDesktopTrayUnread() {
    final count = totalUnreadCount;
    if (DesktopTray.isSupported) {
      unawaited(DesktopTray.setUnreadCount(count));
    }
    if (DesktopLauncherBadge.isSupported) {
      unawaited(DesktopLauncherBadge.setUnreadCount(count));
    }
  }

  void notifySession() {
    _bump(sessionTick);
    super.notifyListeners();
    _syncBrowserTabIndicator();
  }

  void notifyShell() {
    if (UiOverlayPause.active) {
      _pauseShell = true;
      _armOverlayResume();
      return;
    }
    _bump(shellTick);
    super.notifyListeners();
  }

  void notifyInbox() {
    // #region agent log
    agentDebugCountNotify('inbox');
    // #endregion
    // Tray lives outside Flutter overlays — keep the badge current even when
    // inbox UI rebuilds are paused.
    _syncDesktopTrayUnread();
    if (UiOverlayPause.active) {
      _pauseInbox = true;
      _armOverlayResume();
      return;
    }
    _bump(inboxTick);
    super.notifyListeners();
  }

  void notifyChat() {
    // #region agent log
    agentDebugCountNotify('chat');
    // #endregion
    if (UiOverlayPause.active) {
      _pauseChat = true;
      _armOverlayResume();
      return;
    }
    _bump(chatTick);
    super.notifyListeners();
  }

  void notifyTypingOnly() {
    // #region agent log
    agentDebugCountNotify('typing');
    // #endregion
    if (UiOverlayPause.active) return;
    _bump(typingTick);
  }

  void notifyCall() {
    // #region agent log
    agentDebugCountNotify('call');
    // #endregion
    _bump(callTick);
    super.notifyListeners();
    _syncBrowserTabIndicator();
  }

  void notifyChatAndInbox() {
    _syncDesktopTrayUnread();
    if (UiOverlayPause.active) {
      _pauseChat = true;
      _pauseInbox = true;
      _armOverlayResume();
      return;
    }
    _bump(chatTick);
    _bump(inboxTick);
    super.notifyListeners();
  }

  @override
  void notifyListeners() {
    // #region agent log
    agentDebugCountNotify('all');
    // #endregion
    _syncDesktopTrayUnread();
    if (UiOverlayPause.active) {
      _pauseInbox = true;
      _pauseChat = true;
      _pauseShell = true;
      _armOverlayResume();
      return;
    }
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

  void _flashDesktopWindowForCall() {
    unawaited(DesktopCallWindow.flashForIncomingCall());
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
    // Manual Profile preference wins. Otherwise one GPU check: capable (RTX)
    // keeps full animated Privet; software GL / weak boxes get cheap mode.
    await prefs.remove('privet_low_resource');
    final storedLow = prefs.getBool('privet_low_resource_user');
    if (storedLow != null) {
      lowResourceMode = storedLow;
      lowResourceAutoHint = false;
    } else {
      final cheap = await LowResourceAutoDetect.shouldEnableCheapMode();
      lowResourceMode = cheap;
      lowResourceAutoHint = cheap;
    }
    setPrivetLowResource(lowResourceMode);
    // #region agent log
    final capable = await hasCapableGpu();
    agentDebugLog(
      hypothesisId: 'H3',
      location: 'state.dart:bootstrap',
      message: 'gpu/lowResource decision',
      data: {
        'storedLow': storedLow,
        'lowResourceMode': lowResourceMode,
        'lowResourceAutoHint': lowResourceAutoHint,
        'capableGpu': capable,
      },
    );
    // #endregion
    LowResourceAutoDetect.cancel();
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

  Future<void> setLowResourceMode(bool value, {bool auto = false}) async {
    if (lowResourceMode == value) return;
    lowResourceMode = value;
    setPrivetLowResource(value);
    if (auto && value) lowResourceAutoHint = true;
    if (!value) lowResourceAutoHint = false;
    LowResourceAutoDetect.cancel();
    // sessionTick rebuilds MaterialApp (theme + MediaQuery.disableAnimations).
    // Also bump pane ticks: chat/inbox listen only to those, and may be sitting
    // behind a Profile sheet where parent rebuilds alone left emoji/controllers
    // mid-animation — that felt like "Low RAM & CPU sometimes works".
    _bump(sessionTick);
    _bump(shellTick);
    _bump(inboxTick);
    _bump(chatTick);
    super.notifyListeners();
    _syncBrowserTabIndicator();
    final prefs = await _prefs();
    await prefs.remove('privet_low_resource');
    // Persist only explicit user choice — auto GPU probe re-runs next launch.
    if (!auto) {
      await prefs.setBool('privet_low_resource_user', value);
    }
  }

  void clearLowResourceAutoHint() {
    if (!lowResourceAutoHint) return;
    lowResourceAutoHint = false;
    notifySession();
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
    // Prefer the live page origin on web. Native desktop Uri.base is file:// —
    // Uri.origin throws for non-http(s), which used to kill Copy invite on Linux.
    final base = httpOrigin(currentPageUri()) ?? _api.baseUrl;
    // Chat lives under /app/ after the landing split; root / is marketing only.
    return '$base/app/?invite=${Uri.encodeComponent(me.handle)}';
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
    taskHistoryByChat.clear();
    taskHistoryHasMoreByChat.clear();
    taskHistoryLoadingOlder.clear();
    remindersByChat.clear();
    reminderHistoryByChat.clear();
    online.clear();
    lastSeen.clear();
    blocked = [];
    autoAllowControlUserIds.clear();
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
    // #region agent log
    final sw = Stopwatch()..start();
    // #endregion
    try {
      final remote = await _api.messages(id, limit: messagePageSize);
      final existing = messagesByChat[id] ?? const <ChatMessage>[];
      messagesByChat[id] = _mergeMessages(remote, existing);
      hasMoreByChat[id] = remote.length >= messagePageSize;
      historyLoaded.add(id);
      _applyPendingMessages(id);
      notifyListeners();
      // #region agent log
      agentDebugLog(
        hypothesisId: 'H6',
        location: 'state.dart:ensureHistory',
        message: 'history loaded',
        data: {
          'id': id,
          'elapsedMs': sw.elapsedMilliseconds,
          'count': messagesByChat[id]?.length ?? 0,
        },
      );
      // #endregion
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
    // Opening a chat is intentional presence so attachChatSurface can mark-read.
    _lastUserPresence = DateTime.now();
    unlockNotificationAudio();
    // #region agent log
    final sw = Stopwatch()..start();
    agentDebugLog(
      hypothesisId: 'H6',
      location: 'state.dart:openConversation',
      message: 'openConversation begin',
      data: {'id': id},
    );
    // #endregion
    activeConversationId = id;
    typingUserId = typingByChat[id];
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
    if (!remindersByChat.containsKey(id)) {
      try {
        remindersByChat[id] = await _api.reminders(id);
      } catch (_) {
        remindersByChat[id] = [];
      }
    }
    if (!reminderHistoryByChat.containsKey(id)) {
      await refreshReminderHistory(id);
    }
    if (!taskHistoryByChat.containsKey(id)) {
      await refreshTaskHistory(id);
    }
    // Clear unread locally only when this window is actually focused —
    // otherwise an open chat in the background would swallow badges.
    if (idx >= 0 &&
        conversations[idx].unreadCount > 0 &&
        !documentHidden &&
        documentHasFocus) {
      conversations[idx] = conversations[idx].copyWith(unreadCount: 0);
    }
    notifyShell();
    notifyChatAndInbox();
    // Mark read only when this window is focused and recently used.
    if (_canMarkReadNow) {
      _markRead(id, reason: 'openConversation');
    }
    // #region agent log
    agentDebugLog(
      hypothesisId: 'H6',
      location: 'state.dart:openConversation',
      message: 'openConversation end',
      data: {
        'id': id,
        'elapsedMs': sw.elapsedMilliseconds,
        'msgCount': messagesByChat[id]?.length ?? 0,
      },
    );
    // #endregion
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
  ///
  /// When the user returns to an open chat that accumulated unread while AFK,
  /// clear the badge and sync the read cursor immediately (debounced) — otherwise
  /// the count sticks until the next message / tab-focus event.
  void noteUserPresence() {
    _lastUserPresence = DateTime.now();
    unlockNotificationAudio();
    _clearUnreadIfViewingPresent();
  }

  bool get _userRecentlyPresent =>
      DateTime.now().difference(_lastUserPresence) <
      const Duration(seconds: 45);

  bool get _canMarkReadNow =>
      chatSurfaceMounted &&
      !documentHidden &&
      documentHasFocus &&
      _userRecentlyPresent;

  /// Drop the inbox badge for the open chat once the user is present again.
  void _clearUnreadIfViewingPresent() {
    final id = activeConversationId;
    if (id == null || !_canMarkReadNow) return;
    final idx = conversations.indexWhere((c) => c.id == id);
    if (idx < 0 || conversations[idx].unreadCount <= 0) return;
    conversations[idx] = conversations[idx].copyWith(unreadCount: 0);
    notifyInbox();
    _scheduleFocusedRead();
  }

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
    final result = await _api.forwardMessage(
      conversationId: toConversationId,
      messageId: messageId,
    );
    final message = result.message;
    final list = List<ChatMessage>.from(messagesByChat[toConversationId] ?? []);
    if (!list.any((m) => m.id == message.id)) {
      list.add(message);
      messagesByChat[toConversationId] = list;
    }
    final source = result.sourceMessage;
    if (source != null) {
      _replaceMessage(source);
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

  /// Best-effort display name for a peer (DM peer, directory, recent messages).
  String displayNameFor(String? userId) {
    if (userId == null) return 'Someone';
    for (final c in conversations) {
      final peer = c.peer;
      if (peer?.id == userId && peer!.displayName.trim().isNotEmpty) {
        return peer.displayName.trim();
      }
    }
    for (final u in directory) {
      if (u.id == userId && u.displayName.trim().isNotEmpty) {
        return u.displayName.trim();
      }
    }
    for (final list in messagesByChat.values) {
      for (var i = list.length - 1; i >= 0; i--) {
        final s = list[i].sender;
        if (s.id == userId && s.displayName.trim().isNotEmpty) {
          return s.displayName.trim();
        }
      }
    }
    return 'Someone';
  }

  /// Header / bubble label: `"typing…"` in DMs, `"Alex is typing…"` in groups.
  String typingLabel({String? conversationId, bool includeName = false}) {
    final chatId = conversationId ?? activeConversationId;
    if (chatId == null) return 'typing…';
    final typerId = typingByChat[chatId];
    if (typerId == null) return 'typing…';
    if (!includeName) {
      final idx = conversations.indexWhere((c) => c.id == chatId);
      if (idx >= 0 && conversations[idx].isGroup) {
        includeName = true;
      }
    }
    if (!includeName) return 'typing…';
    return '${displayNameFor(typerId)} is typing…';
  }

  bool isTypingIn(String conversationId) => typingByChat.containsKey(conversationId);

  static String _peerMessageKey(String conversationId, String userId) =>
      '$conversationId:$userId';

  void _setPeerTyping(String conversationId, String typerId) {
    // A trailing typing pulse can arrive after their message on the wire.
    // Ignore briefly so the dots do not reappear after the bubble.
    final lastMsg = _lastPeerMessageAt[_peerMessageKey(conversationId, typerId)];
    if (lastMsg != null &&
        DateTime.now().difference(lastMsg) < const Duration(milliseconds: 2000)) {
      return;
    }
    typingByChat[conversationId] = typerId;
    if (conversationId == activeConversationId) {
      typingUserId = typerId;
    }
    _typingClearTimers.remove(conversationId)?.cancel();
    // Client emits every ~800ms while composing; TTL covers a few missed
    // pulses without leaving the indicator stuck after they stop.
    _typingClearTimers[conversationId] = Timer(
      const Duration(milliseconds: 2800),
      () {
        if (typingByChat[conversationId] != typerId) return;
        typingByChat.remove(conversationId);
        if (typingUserId == typerId &&
            activeConversationId == conversationId) {
          typingUserId = null;
        }
        notifyTypingOnly();
        notifyInbox();
      },
    );
    notifyTypingOnly();
    notifyInbox();
  }

  void _clearPeerTyping(String conversationId, {String? onlyUserId}) {
    final current = typingByChat[conversationId];
    if (current == null) return;
    if (onlyUserId != null && current != onlyUserId) return;
    typingByChat.remove(conversationId);
    _typingClearTimers.remove(conversationId)?.cancel();
    if (activeConversationId == conversationId) {
      typingUserId = null;
    }
    notifyTypingOnly();
    notifyInbox();
  }

  /// Drop any pending trailing typing pulse so send cannot re-announce typing.
  void stopOutgoingTyping() {
    _typingThrottle.cancel();
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

  List<TaskItem> taskHistoryFor(String? conversationId) {
    if (conversationId == null) return const [];
    return taskHistoryByChat[conversationId] ?? const [];
  }

  ConversationTasks taskHistoryBoardFor(String? conversationId) =>
      ConversationTasks(items: List<TaskItem>.from(taskHistoryFor(conversationId)));

  bool taskHistoryHasMore(String? conversationId) =>
      conversationId != null && (taskHistoryHasMoreByChat[conversationId] ?? false);

  Future<void> refreshTaskHistory(String conversationId) async {
    try {
      final page = await _api.taskHistory(
        conversationId,
        limit: taskHistoryPageSize,
      );
      taskHistoryByChat[conversationId] = page.items;
      taskHistoryHasMoreByChat[conversationId] = page.hasMore;
    } catch (_) {
      taskHistoryByChat[conversationId] = [];
      taskHistoryHasMoreByChat[conversationId] = false;
    }
    notifyListeners();
  }

  Future<bool> loadOlderTaskHistory(String conversationId) async {
    if (taskHistoryHasMoreByChat[conversationId] != true) return false;
    if (taskHistoryLoadingOlder.contains(conversationId)) return false;
    final existing = taskHistoryByChat[conversationId] ?? const [];
    final roots = existing.where((i) => !i.isSubtask).toList();
    if (roots.isEmpty) {
      taskHistoryHasMoreByChat[conversationId] = false;
      notifyListeners();
      return false;
    }
    final oldest = roots.last;
    final before = oldest.updatedAt ?? oldest.createdAt;
    taskHistoryLoadingOlder.add(conversationId);
    notifyListeners();
    try {
      final page = await _api.taskHistory(
        conversationId,
        limit: taskHistoryPageSize,
        before: _sqlTimestamp(before),
      );
      if (page.items.isEmpty) {
        taskHistoryHasMoreByChat[conversationId] = false;
        return false;
      }
      final seen = existing.map((e) => e.id).toSet();
      final merged = [
        ...existing,
        ...page.items.where((e) => !seen.contains(e.id)),
      ];
      taskHistoryByChat[conversationId] = merged;
      taskHistoryHasMoreByChat[conversationId] = page.hasMore;
      return true;
    } catch (_) {
      return false;
    } finally {
      taskHistoryLoadingOlder.remove(conversationId);
      notifyListeners();
    }
  }

  void _setTasks(String conversationId, List<TaskItem> items) {
    tasksByChat[conversationId] = items;
    notifyListeners();
  }

  Future<TaskItem> addTask({
    required String conversationId,
    required String body,
    String? messageId,
    String? mediaUrl,
    String? mimeType,
    String? fileName,
    List<MediaAttachment>? attachments,
    String? assignedTo,
    String? parentId,
  }) async {
    final result = await _api.createTaskDetailed(
      conversationId: conversationId,
      body: body,
      messageId: messageId,
      mediaUrl: mediaUrl,
      mimeType: mimeType,
      fileName: fileName,
      attachments: attachments?.map((e) => e.toJson()).toList(),
      assignedTo: assignedTo,
      parentId: parentId,
    );
    _setTasks(conversationId, result.items);
    return result.item;
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
    final media = message.mediaItems.take(10).toList();
    await addTask(
      conversationId: message.conversationId,
      body: body,
      messageId: message.id,
      mediaUrl: media.isNotEmpty ? media.first.mediaUrl : null,
      mimeType: media.isNotEmpty ? media.first.mimeType : null,
      fileName: media.isNotEmpty ? media.first.fileName : null,
      attachments: media.isNotEmpty ? media : null,
    );
  }

  Future<void> toggleTaskDone(TaskItem item) async {
    final markingDone = !item.done;
    final items = await _api.updateTask(taskId: item.id, done: markingDone);
    _setTasks(item.conversationId, items);
    if (markingDone) {
      if (!item.isSubtask) {
        // Parent done cascades to all subtasks on the server → group enters history.
        await refreshTaskHistory(item.conversationId);
      } else {
        final board = ConversationTasks(items: items);
        final rootId = item.parentId!;
        final root = board.rootItems.where((t) => t.id == rootId).firstOrNull;
        if (root != null) {
          final subs = board.subtasksOf(rootId);
          final fullyDone =
              root.done && (subs.isEmpty || subs.every((s) => s.done));
          if (fullyDone) {
            await refreshTaskHistory(item.conversationId);
          }
        }
      }
    }
  }

  /// Only the task creator can call this — fully dismisses the task from the active list.
  Future<void> confirmTaskDone(TaskItem item) async {
    final items = await _api.updateTask(taskId: item.id, doneConfirmed: true);
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
    final next = [
      ...item.mediaItems,
      MediaAttachment(
        mediaUrl: mediaUrl,
        kind: (mimeType ?? '').startsWith('image/') ? 'image' : 'file',
        mimeType: mimeType,
        fileName: fileName,
      ),
    ].take(10).toList();
    final items = await _api.updateTask(
      taskId: item.id,
      attachments: next.map((e) => e.toJson()).toList(),
    );
    _setTasks(item.conversationId, items);
  }

  Future<void> setTaskAttachments({
    required TaskItem item,
    required List<MediaAttachment> attachments,
  }) async {
    final items = await _api.updateTask(
      taskId: item.id,
      attachments: attachments.take(10).map((e) => e.toJson()).toList(),
    );
    _setTasks(item.conversationId, items);
  }

  Future<void> clearTaskMedia(TaskItem item) async {
    final items = await _api.updateTask(taskId: item.id, clearMedia: true);
    _setTasks(item.conversationId, items);
  }

  Future<void> removeTaskAttachment(TaskItem item, String mediaUrl) async {
    final next =
        item.mediaItems.where((m) => m.mediaUrl != mediaUrl).toList();
    if (next.isEmpty) {
      await clearTaskMedia(item);
      return;
    }
    await setTaskAttachments(item: item, attachments: next);
  }

  Future<void> deleteTask(TaskItem item) async {
    final items = await _api.deleteTask(item.id);
    _setTasks(item.conversationId, items);
  }

  Future<void> clearDoneTasks(String conversationId) async {
    final items = await _api.clearDoneTasks(conversationId);
    _setTasks(conversationId, items);
  }

  List<PaymentReminder> remindersFor(String? conversationId) {
    if (conversationId == null) return const [];
    return remindersByChat[conversationId] ?? const [];
  }

  List<PaymentReminder> reminderHistoryFor(String? conversationId) {
    if (conversationId == null) return const [];
    return reminderHistoryByChat[conversationId] ?? const [];
  }

  Future<void> refreshReminderHistory(String conversationId) async {
    try {
      reminderHistoryByChat[conversationId] = await _api.reminderHistory(conversationId);
    } catch (_) {
      reminderHistoryByChat[conversationId] = [];
    }
    notifyListeners();
  }

  void _setReminders(String conversationId, List<PaymentReminder> items) {
    remindersByChat[conversationId] = items;
    notifyListeners();
  }

  Future<void> addReminder({
    required String conversationId,
    required String kind,
    int? amountCents,
    required String currency,
    required String direction,
    required String dueDate,
    String note = '',
  }) async {
    final items = await _api.createReminder(
      conversationId: conversationId,
      kind: kind,
      amountCents: amountCents,
      currency: currency,
      direction: direction,
      dueDate: dueDate,
      note: note,
    );
    _setReminders(conversationId, items);
  }

  Future<void> markReminderPaid(PaymentReminder r) async {
    final items = await _api.updateReminder(reminderId: r.id, paid: true);
    _setReminders(r.conversationId, items);
    await refreshReminderHistory(r.conversationId);
  }

  Future<void> snoozeReminder(PaymentReminder r, Duration duration) async {
    final until = DateTime.now().add(duration).toIso8601String();
    final items = await _api.updateReminder(reminderId: r.id, snoozedUntil: until);
    _setReminders(r.conversationId, items);
  }

  Future<void> updateReminderDetails(PaymentReminder r, {
    int? amountCents,
    String? currency,
    String? direction,
    String? dueDate,
    String? note,
  }) async {
    final items = await _api.updateReminder(
      reminderId: r.id,
      amountCents: amountCents,
      currency: currency,
      direction: direction,
      dueDate: dueDate,
      note: note,
    );
    _setReminders(r.conversationId, items);
  }

  Future<void> deleteReminder(PaymentReminder r) async {
    final items = await _api.deleteReminder(r.id);
    _setReminders(r.conversationId, items);
  }

  Future<void> toggleTaskPin(TaskItem item) async {
    final items = await _api.updateTask(taskId: item.id, pinned: !item.pinned);
    _setTasks(item.conversationId, items);
  }

  Future<void> unpinTasksFromHeader(String conversationId) async {
    final items = await _api.unpinAllTasks(conversationId);
    _setTasks(conversationId, items);
  }

  Future<void> toggleReminderPin(PaymentReminder r) async {
    final items = await _api.updateReminder(reminderId: r.id, pinned: !r.pinned);
    _setReminders(r.conversationId, items);
  }

  void _applyReminderLists(
    String conversationId, {
    required List<PaymentReminder> items,
    required List<PaymentReminder> history,
  }) {
    remindersByChat[conversationId] = items;
    reminderHistoryByChat[conversationId] = history;
    notifyListeners();
  }

  Future<void> addPaymentExpense({
    required PaymentReminder payment,
    required String label,
    required int amountCents,
  }) async {
    final result = await _api.createExpense(
      paymentId: payment.id,
      label: label,
      amountCents: amountCents,
    );
    _applyReminderLists(
      payment.conversationId,
      items: result.items,
      history: result.history,
    );
  }

  Future<void> updatePaymentExpense({
    required String conversationId,
    required String expenseId,
    String? label,
    int? amountCents,
  }) async {
    final result = await _api.updateExpense(
      expenseId: expenseId,
      label: label,
      amountCents: amountCents,
    );
    _applyReminderLists(
      conversationId,
      items: result.items,
      history: result.history,
    );
  }

  Future<void> deletePaymentExpense({
    required String conversationId,
    required String expenseId,
  }) async {
    final result = await _api.deleteExpense(expenseId);
    _applyReminderLists(
      conversationId,
      items: result.items,
      history: result.history,
    );
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
    taskHistoryByChat.remove(conversationId);
    taskHistoryHasMoreByChat.remove(conversationId);
    taskHistoryLoadingOlder.remove(conversationId);
    remindersByChat.remove(conversationId);
    reminderHistoryByChat.remove(conversationId);
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

    // Cancel before the WS send so a trailing throttle cannot fire after.
    stopOutgoingTyping();

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

    stopOutgoingTyping();
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
    // Switching chats must not inherit the previous chat's throttle cool-down.
    if (_typingThrottleChatId != chatId) {
      _typingThrottleChatId = chatId;
      _typingThrottle.reset();
    }
    _typingThrottle(() => _rt.typing(chatId));
  }

  /// Announce typing only while the composer still has content.
  /// Clearing the field after send must not emit a trailing pulse.
  void notifyTypingIfComposing(String text) {
    // Keyboard activity counts as presence (pointer-only was leaving the
    // open-chat badge climbing while the user was actively typing).
    noteUserPresence();
    if (text.trim().isEmpty) {
      stopOutgoingTyping();
      return;
    }
    notifyTyping();
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
      withVideo: mode == 'video',
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
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await s.dispose();
    } catch (_) {}
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
    if (mode == 'control') {
      // Dedicated remote control uses [acceptRemoteControl] (picker + inject).
      allowCallTones();
      error =
          'Use Allow control — remote control needs the desktop app and screen capture.';
      notifyListeners();
      return;
    }
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

    // Peer may have hung up while the permission dialog was open.
    if (ringing?.call.id != incoming.call.id) {
      if (preparedLocal != null) {
        for (final t in preparedLocal.getTracks()) {
          await t.stop();
        }
        await preparedLocal.dispose();
      }
      allowCallTones();
      notifyListeners();
      return;
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

  /// Accept a dedicated remote-control invite after the host picked a display
  /// and confirmed OS inject is available.
  Future<void> acceptRemoteControl({required MediaStream displayStream}) async {
    final incoming = ringing;
    final me = user;
    if (incoming == null || me == null) {
      for (final t in displayStream.getTracks()) {
        await t.stop();
      }
      await displayStream.dispose();
      return;
    }
    if (incoming.call.mode != 'control') {
      for (final t in displayStream.getTracks()) {
        await t.stop();
      }
      await displayStream.dispose();
      return;
    }
    suppressCallTones();
    ringing = null;
    notifyListeners();
    wakeUiAfterMediaDialog();
    _rt.acceptCall(incoming.call.id);
    await _beginSession(
      call: incoming.call,
      peer: incoming.peer,
      isCaller: false,
      preparedDisplay: displayStream,
      wantLocalVideo: false,
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
    // Clear before await so a racing call.ended cannot touch a half-disposed session.
    if (session != null) {
      callSession = null;
      session.removeListener(notifyCall);
      _rt.hangupCall(session.call.id, toUserId: session.peerId);
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
    if (session != null) {
      await session.disposeSession();
    }
    _clearPendingRemoteControl();
    notifyListeners();
  }

  /// Peer/server hangup: release media before the messenger rebuilds over
  /// live WebRTC textures (that hitch felt like Privet freezing on Linux).
  Future<void> _handleCallEnded(String? callId) async {
    // #region agent log
    agentDebugLog(
      hypothesisId: 'H4',
      location: 'state.dart:_handleCallEnded',
      message: 'call.ended begin',
      data: {'callId': callId, 'hadSession': callSession != null},
    );
    final sw = Stopwatch()..start();
    // #endregion
    stopAllCallSounds();
    allowCallTones();
    if (callId == null || ringing?.call.id == callId) {
      ringing = null;
    }
    final ended = callSession;
    if (ended != null && (callId == null || ended.call.id == callId)) {
      callSession = null;
      ended.removeListener(notifyCall);
      await ended.disposeSession();
    }
    await _discardPendingDisplay();
    await _discardPendingLocal();
    callMinimized = false;
    resetMiniCallLayout();
    _clearPendingRemoteControl();
    // #region agent log
    agentDebugLog(
      hypothesisId: 'H4',
      location: 'state.dart:_handleCallEnded',
      message: 'call.ended end',
      data: {'elapsedMs': sw.elapsedMilliseconds},
    );
    // #endregion
    notifyListeners();
  }

  Future<void> _beginSession({
    required CallInfo call,
    required PrivetUser peer,
    required bool isCaller,
    MediaStream? preparedLocal,
    MediaStream? preparedDisplay,
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
      if (preparedDisplay != null) {
        for (final t in preparedDisplay.getTracks()) {
          await t.stop();
        }
        await preparedDisplay.dispose();
      }
      return;
    }
    // Connected — never allow ring/ringback to restart for this call.
    suppressCallTones();
    // Caller screen share uses the pending click-time stream; control host
    // passes [preparedDisplay] explicitly as the callee.
    final prepared = preparedDisplay ??
        (isCaller ? _pendingDisplayStream : null);
    if (preparedDisplay == null && isCaller) {
      _pendingDisplayStream = null;
    } else if (identical(prepared, _pendingDisplayStream)) {
      _pendingDisplayStream = null;
    }
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
    // #region agent log
    agentDebugSetHasCall(true);
    agentDebugLog(
      hypothesisId: 'H4',
      location: 'state.dart:_beginSession',
      message: 'call session started',
      data: {'mode': call.mode, 'callId': call.id},
    );
    // #endregion
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
      _applyPendingRemoteControl(session);
      notifyListeners();
    } catch (e) {
      error = 'Could not start media: $e';
      _rt.hangupCall(call.id, toUserId: peer.id);
      session.removeListener(notifyCall);
      await session.disposeSession();
      if (identical(callSession, session)) {
        callSession = null;
      }
      callMinimized = false;
      allowCallTones();
      notifyListeners();
    }
  }

  /// Control grant/deny can race ahead of [CallSession] creation on the
  /// controller — stash and apply once the session exists.
  String? _pendingControlEventCallId;
  String? _pendingControlEventType; // grant | deny
  String? _pendingControlEventReason;

  void _clearPendingRemoteControl() {
    _pendingControlEventCallId = null;
    _pendingControlEventType = null;
    _pendingControlEventReason = null;
  }

  void _stashPendingRemoteControl({
    required String? callId,
    required String type,
    String? reason,
  }) {
    _pendingControlEventCallId = callId;
    _pendingControlEventType = type;
    _pendingControlEventReason = reason;
  }

  void _applyPendingRemoteControl(CallSession session) {
    if (_pendingControlEventCallId != null &&
        _pendingControlEventCallId != session.call.id) {
      return;
    }
    final type = _pendingControlEventType;
    if (type == null) return;
    final reason = _pendingControlEventReason;
    _clearPendingRemoteControl();
    if (type == 'grant') {
      session.remoteControl?.onPeerGrant();
    } else if (type == 'deny') {
      session.remoteControl?.onPeerDeny(reason);
    }
  }

  Future<void> _onIncomingMessage(Map<String, dynamic> event) async {
    if (DesktopTray.isSupported) {
      await refreshDesktopFocusState();
    }

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
    if (!fromSelf) {
      _lastPeerMessageAt[_peerMessageKey(chatId, message.sender.id)] =
          DateTime.now();
      _clearPeerTyping(chatId, onlyUserId: message.sender.id);
    }
    final viewingHere =
        active && chatSurfaceMounted && !documentHidden && documentHasFocus;
    if (!fromSelf) {
      final idx = conversations.indexWhere((c) => c.id == chatId);
      if (idx >= 0) {
        if (viewingHere && _userRecentlyPresent) {
          conversations[idx] = conversations[idx].copyWith(
            unreadCount: 0,
            lastMessage: message,
          );
        } else if (isNew) {
          // Only bump on first delivery — duplicate WS events must not
          // inflate the badge, or it later snaps to 0 and feels random.
          final c = conversations[idx];
          conversations[idx] = c.copyWith(
            unreadCount: c.unreadCount + 1,
            lastMessage: message,
          );
        } else {
          conversations[idx] = conversations[idx].copyWith(
            lastMessage: message,
          );
        }
      }
      // Always ding on every new incoming message (mute is the only off switch).
      // Server sets playSound:false on non-primary sockets so multi-tab /
      // multi-browser logins for the same user only ding once.
      if (isNew &&
          event['playSound'] != false &&
          message.kind != 'call') {
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
      case 'reminders.updated':
        final remChatId = event['conversationId'] as String?;
        if (remChatId != null) {
          final raw = (event['items'] as List?) ?? const [];
          remindersByChat[remChatId] = raw
              .map((e) => PaymentReminder.fromJson(e as Map<String, dynamic>))
              .toList();
          unawaited(refreshReminderHistory(remChatId));
          notifyListeners();
        }
      case 'message':
        unawaited(_onIncomingMessage(event));
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
        final readAt = parseServerUtc(readAtRaw);
        final idx = conversations.indexWhere((c) => c.id == chatId);
        if (idx < 0) return;
        final c = conversations[idx];
        if (readerId == user?.id) {
          conversations[idx] = c.copyWith(
            unreadCount: 0,
            lastReadAt: readAt ?? c.lastReadAt,
          );
          dismissDesktopNotification(chatId);
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
        final chatId = event['conversationId'] as String?;
        final typerId = event['userId'] as String?;
        if (chatId == null ||
            typerId == null ||
            typerId == user?.id) {
          return;
        }
        _setPeerTyping(chatId, typerId);
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
          _flashDesktopWindowForCall();
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
        _flashDesktopWindowForCall();
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
        session.onPeerShareStarted(
          controllable: event['controllable'] == true,
          controlPlatform:
              (event['controlPlatform'] as String?)?.trim() ?? '',
          controlBackend: (event['controlBackend'] as String?)?.trim() ?? '',
          controlDetail: (event['controlDetail'] as String?)?.trim() ?? '',
        );
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
        if (session == null || session.remoteControl == null) {
          _stashPendingRemoteControl(callId: callId, type: 'grant');
          return;
        }
        if (callId != null && callId != session.call.id) return;
        session.remoteControl?.onPeerGrant();
        notifyListeners();
      case 'call.control_deny':
        final callId = event['callId'] as String?;
        final session = callSession;
        if (session == null || session.remoteControl == null) {
          _stashPendingRemoteControl(
            callId: callId,
            type: 'deny',
            reason: event['reason'] as String?,
          );
          return;
        }
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
        unawaited(_handleCallEnded(event['callId'] as String?));
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
      final at = parseServerUtc(entry.value);
      if (at != null) lastSeen['${entry.key}'] = at;
    }
  }

  @override
  void dispose() {
    _focusedReadTimer?.cancel();
    _inboxReconcileTimer?.cancel();
    _typingThrottle.cancel();
    for (final t in _typingClearTimers.values) {
      t.cancel();
    }
    _typingClearTimers.clear();
    _lastPeerMessageAt.clear();
    _disposeVisibility?.call();
    _disposeVisibility = null;
    callSession?.disposeSession();
    _rt.disconnect();
    LowResourceAutoDetect.cancel();
    sessionTick.dispose();
    shellTick.dispose();
    inboxTick.dispose();
    chatTick.dispose();
    typingTick.dispose();
    callTick.dispose();
    super.dispose();
  }
}
