import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

bool get isSupported =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows);

const _kWindowsPort = 47831;

ServerSocket? _server;

Future<bool> ensurePrimary({void Function()? onRaise}) async {
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

Future<void> shutdown() async {
  final server = _server;
  _server = null;
  if (server != null) {
    try {
      await server.close();
    } catch (_) {}
  }
}

Future<void> _handleRaiseClient(Socket client, void Function()? onRaise) async {
  try {
    await client.drain<void>();
    onRaise?.call();
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
    socket.write('raise');
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
    socket.write('raise');
    await socket.flush();
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
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
