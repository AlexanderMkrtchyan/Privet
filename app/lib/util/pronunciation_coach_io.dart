import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'pronunciation_result.dart';

const _port = 8765;
const _host = '127.0.0.1';
Future<void>? _serverStartup;

Uri get _healthUri => Uri.parse('http://$_host:$_port/health');
Uri get _assessUri => Uri.parse('http://$_host:$_port/assess');

String? _home() {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;
  final dir = Directory('$home/pronounce');
  final python = File('${dir.path}/.venv/bin/python');
  final serve = File('${dir.path}/serve.py');
  if (!python.existsSync() || !serve.existsSync()) return null;
  return dir.path;
}

Future<Map<String, dynamic>?> _health() async {
  try {
    final res = await http.get(_healthUri).timeout(const Duration(seconds: 2));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body);
    if (json is! Map) return null;
    return Map<String, dynamic>.from(json);
  } catch (_) {
    return null;
  }
}

Future<void> _startServer(String home) async {
  final log = File('$home/serve.log');
  final sink = log.openWrite(mode: FileMode.append);
  final python = '$home/.venv/bin/python';
  final espeakBin = '$home/espeak-root/usr/bin';
  final espeakLib = '$home/espeak-root/usr/lib/x86_64-linux-gnu';
  final env = Map<String, String>.from(Platform.environment);
  env['PATH'] = '$espeakBin:${env['PATH'] ?? ''}';
  env['LD_LIBRARY_PATH'] = '$espeakLib:${env['LD_LIBRARY_PATH'] ?? ''}';
  env['OPENPRONOUNCE_DEVICE'] = 'cuda';
  final proc = await Process.start(
    python,
    ['$home/serve.py'],
    environment: env,
    workingDirectory: home,
    mode: ProcessStartMode.detachedWithStdio,
  );
  proc.stdout.listen(sink.add, onDone: sink.close);
  proc.stderr.listen(sink.add);
}

/// Starts the local model if it is not already listening. Throws [StateError]
/// with a message the dialog can show.
Future<void> ensurePronunciationServer({
  Duration timeout = const Duration(seconds: 90),
}) async {
  final startup = _serverStartup;
  if (startup != null) return startup;
  final future = _ensurePronunciationServer(timeout);
  _serverStartup = future;
  try {
    await future;
  } finally {
    if (identical(_serverStartup, future)) _serverStartup = null;
  }
}

Future<void> _ensurePronunciationServer(Duration timeout) async {
  final existing = await _health();
  if (existing != null && existing['ready'] == true) return;
  if (existing != null && existing['error'] != null) {
    throw StateError('Pronunciation model failed to load');
  }
  if (existing == null) {
    final home = _home();
    if (home == null) {
      throw StateError('Pronunciation model is not installed in ~/pronounce');
    }
    await _startServer(home);
  }
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final health = await _health();
    if (health != null && health['ready'] == true) return;
    if (health != null && health['error'] != null) {
      throw StateError('Pronunciation model failed to load');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  throw StateError('Pronunciation model took too long to load');
}

Future<bool> pronunciationModelReady() async {
  final health = await _health();
  return health?['ready'] == true;
}

Future<PronunciationAssessment> assessPronunciation(
  Uint8List wav,
  String text,
) async {
  await ensurePronunciationServer();
  final request = http.MultipartRequest('POST', _assessUri);
  request.fields['text'] = text;
  request.files.add(
    http.MultipartFile.fromBytes(
      'file',
      wav,
      filename: 'read.wav',
      contentType: MediaType('audio', 'wav'),
    ),
  );
  final streamed = await request.send().timeout(const Duration(seconds: 45));
  final body = await streamed.stream.bytesToString();
  if (streamed.statusCode != 200) {
    throw StateError(_errorMessage(streamed.statusCode, body));
  }
  return PronunciationAssessment.parse(body);
}

String _errorMessage(int status, String body) {
  try {
    final json = jsonDecode(body);
    if (json is Map && json['detail'] is String) {
      return json['detail'] as String;
    }
  } catch (_) {}
  if (status == 503) return 'The model is still loading — try again';
  return 'Could not score the recording';
}
