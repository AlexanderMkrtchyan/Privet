import 'app_update_stub.dart'
    if (dart.library.io) 'app_update_io.dart' as impl;

/// Latest desktop release metadata from `/version.json`.
class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.buildNumber,
    this.windowsSetupUrl,
    this.linuxDebUrl,
    this.linuxTarUrl,
  });

  final String version;
  final String buildNumber;
  final String? windowsSetupUrl;
  final String? linuxDebUrl;
  final String? linuxTarUrl;

  factory AppReleaseInfo.fromJson(Map<String, dynamic> json) {
    final windows = json['windows'];
    final linux = json['linux'];
    String? winUrl = json['windows_setup_url']?.toString();
    String? debUrl = json['linux_deb_url']?.toString();
    String? tarUrl = json['linux_tar_url']?.toString();
    if (windows is Map) {
      winUrl ??= windows['setup_url']?.toString();
    }
    if (linux is Map) {
      debUrl ??= linux['deb_url']?.toString();
      tarUrl ??= linux['tar_url']?.toString();
    }
    return AppReleaseInfo(
      version: json['version']?.toString() ?? '',
      buildNumber: json['build_number']?.toString() ?? '',
      windowsSetupUrl: winUrl,
      linuxDebUrl: debUrl,
      linuxTarUrl: tarUrl,
    );
  }
}

class AppUpdateStatus {
  const AppUpdateStatus({
    required this.currentVersion,
    required this.currentBuild,
    required this.updateAvailable,
    required this.supportsInAppUpdate,
    this.latest,
  });

  final String currentVersion;
  final String currentBuild;
  final bool updateAvailable;
  final bool supportsInAppUpdate;
  final AppReleaseInfo? latest;

  static const unavailable = AppUpdateStatus(
    currentVersion: '',
    currentBuild: '',
    updateAvailable: false,
    supportsInAppUpdate: false,
  );
}

/// Compare dotted versions; optional build numbers as tiebreaker.
/// Returns negative if [a] < [b], zero if equal, positive if [a] > [b].
int compareAppVersions(
  String aVersion,
  String aBuild,
  String bVersion,
  String bBuild,
) {
  final av = _parseParts(aVersion);
  final bv = _parseParts(bVersion);
  final n = av.length > bv.length ? av.length : bv.length;
  for (var i = 0; i < n; i++) {
    final ai = i < av.length ? av[i] : 0;
    final bi = i < bv.length ? bv[i] : 0;
    if (ai != bi) return ai.compareTo(bi);
  }
  final ab = int.tryParse(aBuild.trim()) ?? 0;
  final bb = int.tryParse(bBuild.trim()) ?? 0;
  return ab.compareTo(bb);
}

List<int> _parseParts(String version) {
  final cleaned = version.trim().split(RegExp(r'[^0-9.]')).first;
  if (cleaned.isEmpty) return const [0];
  return cleaned
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList(growable: false);
}

/// Desktop in-app updates (Windows silent installer today).
abstract final class AppUpdate {
  static bool get supportsInAppUpdate => impl.supportsInAppUpdate;

  static Future<AppUpdateStatus> check({required String baseUrl}) =>
      impl.check(baseUrl: baseUrl);

  /// Download the Windows setup and run a silent upgrade, then exit.
  /// [onProgress] is 0..1 while downloading.
  static Future<void> applyWindowsUpdate({
    required String setupUrl,
    void Function(double progress)? onProgress,
  }) =>
      impl.applyWindowsUpdate(setupUrl: setupUrl, onProgress: onProgress);
}
