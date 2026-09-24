import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Opens the OS file manager with [path] selected.
Future<bool> revealInFileManager(String path) async {
  final file = File(path);
  if (!await file.exists()) return false;
  if (Platform.isLinux) {
    if (await _showItemsDbus(path)) return true;
    if (await _tryProcess('nautilus', ['--select', path])) return true;
    if (await _tryProcess('dolphin', ['--select', path])) return true;
    if (await _tryProcess('nemo', [path])) return true;
    return _tryProcess('xdg-open', [p.dirname(path)]);
  }
  if (Platform.isWindows) {
    return _tryProcess('explorer', ['/select,', path]);
  }
  if (Platform.isMacOS) {
    return _tryProcess('open', ['-R', path]);
  }
  return _tryProcess('xdg-open', [p.dirname(path)]);
}

Future<bool> _showItemsDbus(String path) async {
  DBusClient? client;
  try {
    client = DBusClient.session();
    final object = DBusRemoteObject(
      client,
      name: 'org.freedesktop.FileManager1',
      path: DBusObjectPath('/org/freedesktop/FileManager1'),
    );
    final uri = Uri.file(path).toString();
    await object.callMethod(
      'org.freedesktop.FileManager1',
      'ShowItems',
      [
        DBusArray.string([uri]),
        const DBusString(''),
      ],
    );
    return true;
  } catch (e) {
    debugPrint('revealInFileManager: D-Bus ShowItems failed: $e');
    return false;
  } finally {
    await client?.close();
  }
}

Future<bool> _tryProcess(String command, List<String> args) async {
  try {
    final result = await Process.run(command, args);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
