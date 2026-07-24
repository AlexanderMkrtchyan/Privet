import 'package:url_launcher/url_launcher.dart';

Future<void> downloadMedia(String url, {String? filename}) async {
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
