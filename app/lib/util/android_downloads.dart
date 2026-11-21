import 'dart:io';

import 'package:flutter/services.dart';

import 'media_kind.dart';

/// Android bridge for putting downloaded chat media into the *public*
/// Downloads collection. Other platforms write the file themselves, so every
/// helper here is a no-op off Android (the channel only exists there).
const MethodChannel _channel = MethodChannel('privet/downloads');

/// True when files must be handed to Android instead of written to a path.
bool get usesAndroidDownloads => Platform.isAndroid;

/// Copies [sourcePath] into the phone's Downloads folder (MediaStore on
/// Android 10+, public Download/ on older versions). Returns the saved path,
/// or null when the copy failed.
Future<String?> savePathToAndroidDownloads({
  required String sourcePath,
  required String filename,
}) async {
  if (!Platform.isAndroid) return null;
  try {
    final path = await _channel.invokeMethod<String>('saveFile', {
      'path': sourcePath,
      'filename': filename,
      'mimeType': mimeForFilename(filename),
    });
    return (path == null || path.isEmpty) ? null : path;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Opens the downloaded file (or the system Downloads screen) on Android.
Future<bool> revealAndroidDownload(String path) async {
  if (!Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('reveal', {'path': path}) ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
