import 'app_update.dart';

bool get supportsInAppUpdate => false;

Future<AppUpdateStatus> check({required String baseUrl}) async =>
    AppUpdateStatus.unavailable;

Future<void> applyWindowsUpdate({
  required String setupUrl,
  void Function(double progress)? onProgress,
}) async {
  throw UnsupportedError('In-app updates are not available on this platform.');
}
