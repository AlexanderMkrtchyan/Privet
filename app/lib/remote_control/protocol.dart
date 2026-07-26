import 'dart:convert';
import 'dart:math' as math;

/// Wire version for the Privet remote-control data channel.
const int kRemoteControlProtocolVersion = 1;

/// Max UTF-8 size for a single data-channel payload (bytes).
const int kRemoteControlMaxMessageBytes = 2048;

/// Soft cap on input events accepted per second on the host.
const int kRemoteControlMaxEventsPerSecond = 120;

/// Authorization lifecycle for attended remote control.
enum RemoteControlAuth {
  idle,
  requested,
  granted,
  denied,
}

/// Who we are relative to an active control session.
enum RemoteControlRole {
  none,
  controller,
  host,
}

/// Pure protocol helpers — no Flutter/WebRTC imports so unit tests stay light.
class RemoteControlProtocol {
  RemoteControlProtocol._();

  static Map<String, dynamic>? decode(String raw) {
    if (raw.length > kRemoteControlMaxMessageBytes) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final v = map['v'];
      if (v is! int || v != kRemoteControlProtocolVersion) return null;
      final t = map['t'];
      if (t is! String || t.isEmpty) return null;
      return map;
    } catch (_) {
      return null;
    }
  }

  static String encode(Map<String, dynamic> message) {
    final body = <String, dynamic>{
      'v': kRemoteControlProtocolVersion,
      ...message,
    };
    return jsonEncode(body);
  }

  static String pointerMove({
    required double x,
    required double y,
    int buttons = 0,
  }) =>
      encode({
        't': 'ptr',
        'a': 'move',
        'x': _clamp01(x),
        'y': _clamp01(y),
        'b': buttons,
      });

  static String pointerButton({
    required double x,
    required double y,
    required int button,
    required bool down,
    int buttons = 0,
  }) =>
      encode({
        't': 'ptr',
        'a': down ? 'down' : 'up',
        'x': _clamp01(x),
        'y': _clamp01(y),
        'btn': button,
        'b': buttons,
      });

  static String wheel({
    required double x,
    required double y,
    required double dx,
    required double dy,
  }) =>
      encode({
        't': 'wheel',
        'x': _clamp01(x),
        'y': _clamp01(y),
        'dx': dx.clamp(-2400.0, 2400.0),
        'dy': dy.clamp(-2400.0, 2400.0),
      });

  static String keyEvent({
    required String code,
    required bool down,
    int mods = 0,
    String? key,
  }) =>
      encode({
        't': 'key',
        'code': code,
        'down': down,
        'mods': mods,
        if (key != null && key.isNotEmpty) 'key': key,
      });

  static String geometry({required int width, required int height}) => encode({
        't': 'geom',
        'w': width.clamp(1, 16384),
        'h': height.clamp(1, 16384),
      });

  static String heartbeat() => encode({'t': 'hb'});

  static String releaseAll() => encode({'t': 'release'});

  /// Map a point inside a letterboxed video viewport to normalized [0,1] coords
  /// on the shared display, or null when the point is in the letterbox.
  static ({double x, double y})? mapLetterboxedPoint({
    required double localX,
    required double localY,
    required double viewportWidth,
    required double viewportHeight,
    required double contentAspect,
  }) {
    if (viewportWidth <= 0 || viewportHeight <= 0 || contentAspect <= 0) {
      return null;
    }
    final viewAspect = viewportWidth / viewportHeight;
    late final double contentW;
    late final double contentH;
    late final double originX;
    late final double originY;
    if (viewAspect > contentAspect) {
      contentH = viewportHeight;
      contentW = viewportHeight * contentAspect;
      originX = (viewportWidth - contentW) / 2;
      originY = 0;
    } else {
      contentW = viewportWidth;
      contentH = viewportWidth / contentAspect;
      originX = 0;
      originY = (viewportHeight - contentH) / 2;
    }
    final px = localX - originX;
    final py = localY - originY;
    if (px < 0 || py < 0 || px > contentW || py > contentH) return null;
    return (x: _clamp01(px / contentW), y: _clamp01(py / contentH));
  }

  static double _clamp01(double v) => math.min(1.0, math.max(0.0, v));
}

/// Tracks grant state and rejects control when unauthorized.
class RemoteControlSessionState {
  RemoteControlAuth auth = RemoteControlAuth.idle;
  RemoteControlRole role = RemoteControlRole.none;
  int displayWidth = 0;
  int displayHeight = 0;
  DateTime? grantedAt;
  DateTime? lastHeartbeatAt;

  /// Sliding window for host-side rate limiting.
  final List<DateTime> _eventTimes = [];

  bool get isGranted => auth == RemoteControlAuth.granted;
  bool get isController => role == RemoteControlRole.controller && isGranted;
  bool get isHost => role == RemoteControlRole.host && isGranted;

  bool get hasGeometry => displayWidth > 0 && displayHeight > 0;

  void reset() {
    auth = RemoteControlAuth.idle;
    role = RemoteControlRole.none;
    displayWidth = 0;
    displayHeight = 0;
    grantedAt = null;
    lastHeartbeatAt = null;
    _eventTimes.clear();
  }

  void markRequested({required bool asController}) {
    auth = RemoteControlAuth.requested;
    role = asController ? RemoteControlRole.controller : RemoteControlRole.host;
  }

  void markGranted({required bool asController}) {
    auth = RemoteControlAuth.granted;
    role = asController ? RemoteControlRole.controller : RemoteControlRole.host;
    grantedAt = DateTime.now();
    lastHeartbeatAt = grantedAt;
  }

  void markDenied() {
    auth = RemoteControlAuth.denied;
    role = RemoteControlRole.none;
    grantedAt = null;
  }

  void markRevoked() => reset();

  void noteHeartbeat() => lastHeartbeatAt = DateTime.now();

  /// Returns false when the host should drop the event (rate / auth).
  bool acceptHostEvent(DateTime now) {
    if (!isHost) return false;
    _eventTimes.removeWhere((t) => now.difference(t).inMilliseconds > 1000);
    if (_eventTimes.length >= kRemoteControlMaxEventsPerSecond) return false;
    _eventTimes.add(now);
    return true;
  }

  /// Heartbeat older than [timeout] means the controller vanished.
  bool heartbeatExpired({
    Duration timeout = const Duration(seconds: 12),
    DateTime? now,
  }) {
    if (!isGranted || lastHeartbeatAt == null) return false;
    return (now ?? DateTime.now()).difference(lastHeartbeatAt!) > timeout;
  }
}

/// Logical mouse buttons (match Flutter: 1=primary, 2=secondary, 4=middle).
abstract final class RemotePointerButton {
  static const int primary = 1;
  static const int secondary = 2;
  static const int middle = 4;
}

/// Modifier bitfield for key events.
abstract final class RemoteKeyMods {
  static const int shift = 1;
  static const int ctrl = 2;
  static const int alt = 4;
  static const int meta = 8;
}

/// Viewer-facing copy when the peer's share cannot be controlled.
///
/// [peerPlatform] / [peerDetail] come from `call.share_started` capability
/// fields. Browser wording is used only when the host reported `web`.
String remoteControlUnavailableReason({
  required bool peerShareControllable,
  String peerPlatform = '',
  String peerDetail = '',
}) {
  if (peerShareControllable) return '';
  final platform = peerPlatform.trim().toLowerCase();
  final detail = peerDetail.trim();
  if (platform == 'web') {
    return 'Their share is from a browser — only the Ubuntu/Windows app can be controlled.';
  }
  if (detail.isNotEmpty) {
    return 'Their desktop app cannot be controlled: $detail';
  }
  if (platform == 'windows' || platform == 'linux') {
    return 'Their Ubuntu/Windows app cannot inject input on this machine '
        '(missing permissions or an outdated install).';
  }
  return 'Their share cannot be controlled remotely. '
      'They need a current Privet Windows or Linux desktop app.';
}

/// Controller-facing copy after `call.control_deny`.
String remoteControlDeniedReason(String? reason) {
  final trimmed = reason?.trim() ?? '';
  if (trimmed.isNotEmpty) return trimmed;
  return 'Remote control was denied.';
}

/// Host dialog body when this device cannot grant control.
String remoteControlHostCannotInjectMessage({
  required String platform,
  required String detail,
}) {
  final p = platform.trim().toLowerCase();
  final d = detail.trim();
  if (p == 'web') {
    final base =
        'Remote desktop control needs the Privet desktop app on this computer. '
        'A browser tab cannot move your mouse or type on your behalf.';
    return d.isEmpty ? base : '$base\n\n$d';
  }
  final base =
      'This Privet install cannot inject mouse and keyboard input, so remote '
      'control cannot be granted.';
  if (d.isNotEmpty) return '$base\n\n$d';
  return base;
}
