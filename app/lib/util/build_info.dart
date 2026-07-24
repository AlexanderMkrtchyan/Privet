/// Deploy stamp injected via `--dart-define=PRIVET_BUILD=...`.
/// Matches `server/public/BUILD_STAMP.txt` for the web build.
const privetBuildStamp = String.fromEnvironment(
  'PRIVET_BUILD',
  defaultValue: 'dev',
);

/// Short badge label (HHMMSS from `YYYYMMDD-HHMMSS`, else full stamp).
String get privetBuildBadge {
  final s = privetBuildStamp;
  final i = s.lastIndexOf('-');
  if (i >= 0 && i + 1 < s.length) return s.substring(i + 1);
  return s;
}
