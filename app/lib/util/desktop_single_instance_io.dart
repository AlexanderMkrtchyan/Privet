import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

bool get isSupported =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows);

const _kWindowsPort = 47831;

ServerSocket? _server;

/// Payload a second launch writes on the session socket.
///
/// A following line is the xdg-activation token GNOME attached to that launch.
String raisePayload({String? activationToken}) {
  final token = activationToken?.trim();
  if (token == null || token.isEmpty) return 'raise';
  return 'raise\n$token';
}

/// Token from [raisePayload], or null when the peer only asked to focus.
String? activationTokenFromRaisePayload(String payload) {
  final lines = payload.split('\n');
  if (lines.isEmpty || lines.first.trim() != 'raise') return null;
  if (lines.length < 2) return null;
  final token = lines[1].trim();
  if (token.isEmpty || token.length > 512) return null;
  return token;
}

Future<bool> ensurePrimary({void Function(String? activationToken)? onRaise}) async {
  if (!isSupported) return true;

  if (Platform.isWindows) {
    if (await _pingWindows()) return false;
    try {
      _server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _kWindowsPort,
      );
    } on SocketException {
      if (await _pingWindows()) return false;
      return false;
    }
  } else {
    final path = await _socketPath();
    if (await _pingUnix(path)) return false;
    await _prepareSocketFile(path);
    try {
      _server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
    } on SocketException {
      if (await _pingUnix(path)) return false;
      return false;
    }
  }

  _server!.listen((client) {
    unawaited(_handleRaiseClient(client, onRaise));
  });
  return true;
}

/// Second launch must leave the process. Returning from `main` after
/// [WidgetsFlutterBinding.ensureInitialized] keeps a hidden GTK window alive.
void exitSecondary() {
  exit(0);
}

Future<void> shutdown() async {
  final server = _server;
  _server = null;
  if (server != null) {
    try {
      await server.close();
    } catch (_) {}
  }
}

Future<void> _handleRaiseClient(
  Socket client,
  void Function(String? activationToken)? onRaise,
) async {
  try {
    final bytes = await client.fold<List<int>>(<int>[], (prev, chunk) {
      prev.addAll(chunk);
      return prev;
    });
    final token = activationTokenFromRaisePayload(utf8.decode(bytes));
    onRaise?.call(token);
  } catch (_) {
  } finally {
    await client.close();
  }
}

Future<bool> _pingWindows() async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _kWindowsPort,
    );
    socket.write(_raiseMessage());
    await socket.flush();
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<bool> _pingUnix(String path) async {
  try {
    final socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    socket.write(_raiseMessage());
    await socket.flush();
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

String _raiseMessage() {
  final token = Platform.environment['PRIVET_ACTIVATION_TOKEN'];
  return raisePayload(activationToken: token);
}

Future<String> _socketPath() async {
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  if (runtime != null && runtime.isNotEmpty) {
    return p.join(runtime, 'privet.sock');
  }
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, 'privet.sock');
}

Future<void> _prepareSocketFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return;
  // Stale socket from a crashed process — remove before bind.
  if (!await _pingUnix(path)) {
    try {
      await file.delete();
    } catch (_) {}
  }
}
