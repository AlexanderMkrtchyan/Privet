import 'package:url_launcher/url_launcher.dart';

/// Fallback for platforms with no dedicated download path (tests): hand the
/// URL to the system default application. Returns null — no local path.
Future<String?> downloadMedia(String url, {String? filename}) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
  return null;
}
