/// Deploy stamp injected via `--dart-define=PRIVET_BUILD=...`.
/// Matches `server/public/BUILD_STAMP.txt` for the web build.
const privetBuildStamp = String.fromEnvironment(
  'PRIVET_BUILD',
  defaultValue: 'dev',
);

/// Marketing version from `--dart-define=PRIVET_VERSION=...` (pubspec `x.y.z`).
/// Used as a reliable fallback when [PackageInfo] is slow or unavailable.
const privetAppVersion = String.fromEnvironment(
  'PRIVET_VERSION',
  defaultValue: '',
);

/// Build number from `--dart-define=PRIVET_BUILD_NUMBER=...` (pubspec `+N`).
const privetAppBuildNumber = String.fromEnvironment(
  'PRIVET_BUILD_NUMBER',
  defaultValue: '',
);

/// Short badge label (HHMMSS from `YYYYMMDD-HHMMSS`, else full stamp).
String get privetBuildBadge {
  final s = privetBuildStamp;
  final i = s.lastIndexOf('-');
  if (i >= 0 && i + 1 < s.length) return s.substring(i + 1);
  return s;
}

/// Label shown in Profile settings, e.g. `0.1.26 (10)`.
String formatPrivetVersionLabel({
  String version = '',
  String buildNumber = '',
}) {
  final v = version.trim().isNotEmpty ? version.trim() : privetAppVersion;
  final b =
      buildNumber.trim().isNotEmpty ? buildNumber.trim() : privetAppBuildNumber;
  if (v.isEmpty && b.isEmpty) return '';
  if (b.isEmpty) return v;
  if (v.isEmpty) return b;
  return '$v ($b)';
}
