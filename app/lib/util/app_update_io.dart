import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_update.dart';

bool get supportsInAppUpdate => Platform.isWindows;

Future<AppUpdateStatus> check({required String baseUrl}) async {
  final info = await PackageInfo.fromPlatform();
  final currentVersion = info.version;
  final currentBuild = info.buildNumber;

  if (!Platform.isWindows) {
    return AppUpdateStatus(
      currentVersion: currentVersion,
      currentBuild: currentBuild,
      updateAvailable: false,
      supportsInAppUpdate: false,
    );
  }

  try {
    final origin = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final res = await http
        .get(Uri.parse('$origin/version.json'))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return AppUpdateStatus(
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        updateAvailable: false,
        supportsInAppUpdate: true,
      );
    }
    final body = jsonDecode(res.body);
    if (body is! Map<String, dynamic>) {
      return AppUpdateStatus(
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        updateAvailable: false,
        supportsInAppUpdate: true,
      );
    }
    final latest = AppReleaseInfo.fromJson(body);
    final newer = compareAppVersions(
          currentVersion,
          currentBuild,
          latest.version,
          latest.buildNumber,
        ) <
        0;
    final setup = latest.windowsSetupUrl;
    final hasSetup = setup != null && setup.trim().isNotEmpty;
    return AppUpdateStatus(
      currentVersion: currentVersion,
      currentBuild: currentBuild,
      updateAvailable: newer && hasSetup,
      supportsInAppUpdate: true,
      latest: latest,
    );
  } catch (_) {
    return AppUpdateStatus(
      currentVersion: currentVersion,
      currentBuild: currentBuild,
      updateAvailable: false,
      supportsInAppUpdate: true,
    );
  }
}

Future<void> applyWindowsUpdate({
  required String setupUrl,
  void Function(double progress)? onProgress,
}) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Silent in-app update is only supported on Windows.');
  }

  final uri = Uri.parse(setupUrl);
  if (!uri.hasScheme) {
    throw ArgumentError('setupUrl must be absolute, got: $setupUrl');
  }

  final dir = await getTemporaryDirectory();
  final setupPath = p.join(dir.path, 'Privet-Setup-update.exe');
  final file = File(setupPath);
  if (await file.exists()) {
    await file.delete();
  }

  final client = http.Client();
  try {
    final request = http.Request('GET', uri);
    final response = await client.send(request).timeout(
          const Duration(minutes: 10),
        );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Download failed (${response.statusCode})',
        uri: uri,
      );
    }
    final total = response.contentLength ?? 0;
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    onProgress?.call(1);
  } finally {
    client.close();
  }

  // Silent upgrade: close running app files, install over previous dir, relaunch.
  await Process.start(
    setupPath,
    const [
      '/VERYSILENT',
      '/NORESTART',
      '/SUPPRESSMSGBOXES',
      '/FORCECLOSEAPPLICATIONS',
    ],
    mode: ProcessStartMode.detached,
  );

  // Give the installer a moment to spawn, then quit so files unlock.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  exit(0);
}
