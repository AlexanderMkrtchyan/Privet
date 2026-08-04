import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Debug-mode instrumentation: ships NDJSON lines to the local ingest server.
/// Fire-and-forget — never throws and never blocks the caller.
const String _endpoint =
    'http://127.0.0.1:7608/ingest/14ebae12-cf97-4f7e-8e28-7a60bd61aed8';
const String _sessionId = '7d3d83';

int _seq = 0;

/// Send one debug log line. Safe to call from any platform.
void agentDebugLog({
  required String hypothesisId,
  required String location,
  required String message,
  Map<String, dynamic>? data,
  String runId = 'r2',
}) {
  try {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final payload = <String, dynamic>{
      'sessionId': _sessionId,
      'id': 'log_${ts}_${_seq++}',
      'timestamp': ts,
      'location': location,
      'message': message,
      'data': data ?? <String, dynamic>{},
      'hypothesisId': hypothesisId,
      'runId': runId,
    };
    final body = jsonEncode(payload);
    unawaited(
      http
          .post(
            Uri.parse(_endpoint),
            headers: const {
              'Content-Type': 'application/json',
              'X-Debug-Session-Id': _sessionId,
            },
            body: body,
          )
          .then<void>((_) {})
          .catchError((Object _) {}),
    );
  } catch (_) {}
}
