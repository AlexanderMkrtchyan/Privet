import 'dart:convert';

/// Packed body for chat `kind: call` history rows (Teams-style).
class CallHistoryPayload {
  CallHistoryPayload({
    required this.mode,
    required this.outcome,
    required this.durationSec,
    this.callId,
  });

  /// Invite mode: audio | video | screen | control
  final String mode;

  /// completed | missed | declined | canceled
  final String outcome;
  final int durationSec;
  final String? callId;

  static CallHistoryPayload? tryParse(String body) {
    final raw = body.trim();
    if (raw.isEmpty || raw[0] != '{') return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final mode = (map['mode'] as String?)?.trim() ?? 'video';
      final outcome = (map['outcome'] as String?)?.trim() ?? 'completed';
      final dur = (map['durationSec'] as num?)?.toInt() ?? 0;
      return CallHistoryPayload(
        mode: mode,
        outcome: outcome,
        durationSec: dur < 0 ? 0 : dur,
        callId: map['callId'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  String get modeLabel {
    switch (mode) {
      case 'audio':
        return 'Audio call';
      case 'screen':
        return 'Screen share';
      case 'control':
        return 'Remote control';
      default:
        return 'Video call';
    }
  }

  String get modeLabelLower => modeLabel.toLowerCase();

  /// Teams-style duration: `0:45`, `5:32`, `1:02:15`.
  static String formatDuration(int totalSec) {
    final s = totalSec < 0 ? 0 : totalSec;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final r = s % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
    }
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  /// Chat row + conversation list label.
  String get label {
    switch (outcome) {
      case 'missed':
        return 'Missed $modeLabelLower';
      case 'declined':
        return 'Declined $modeLabelLower';
      case 'canceled':
        return 'Canceled $modeLabelLower';
      default:
        return '$modeLabel · ${formatDuration(durationSec)}';
    }
  }

  /// Prefer structured label; fall back to raw body (API list previews).
  static String preview(String body) {
    final parsed = tryParse(body);
    if (parsed != null) return parsed.label;
    final trimmed = body.trim();
    return trimmed.isEmpty ? 'Call' : trimmed;
  }
}
