import 'media_permissions.dart';

Future<MediaPermissionStatus> queryMediaPermissions() async {
  return const MediaPermissionStatus(
    hasMicrophone: true,
    hasCamera: true,
    micGranted: true,
    cameraGranted: true,
    canQuery: false,
    hasDisplayCapture: true,
  );
}

Future<MediaPermissionStatus> requestMediaPermissions({
  bool camera = false,
}) async {
  return queryMediaPermissions();
}

void markMediaGranted({required bool mic, required bool camera}) {}

void listenMediaDeviceChanges(void Function() onChange) {}

void cancelMediaDeviceChanges() {}
