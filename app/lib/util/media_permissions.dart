import 'media_permissions_stub.dart'
    if (dart.library.html) 'media_permissions_web.dart' as impl;

class MediaPermissionStatus {
  const MediaPermissionStatus({
    required this.hasMicrophone,
    required this.hasCamera,
    required this.micGranted,
    required this.cameraGranted,
    required this.canQuery,
    this.hasDisplayCapture = true,
  });

  final bool hasMicrophone;
  final bool hasCamera;
  /// True when mic permission is granted (or assumed on platforms without query).
  final bool micGranted;
  /// True when camera permission is granted (or assumed on platforms without query).
  final bool cameraGranted;
  final bool canQuery;
  /// Browser supports getDisplayMedia (screen/window capture — not the webcam).
  final bool hasDisplayCapture;

  bool get audioReady => hasMicrophone && micGranted;
  bool get videoReady => hasCamera && cameraGranted && audioReady;
  /// Screen share captures the display, not the camera or mic.
  bool get screenReady => hasDisplayCapture;

  bool get canStartAudio => hasMicrophone;
  bool get canStartVideo => hasMicrophone && hasCamera;
  bool get canStartScreen => hasDisplayCapture;
}

Future<MediaPermissionStatus> queryMediaPermissions() =>
    impl.queryMediaPermissions();

/// Soft-prompts mic/camera only when invoked from a user gesture (call click).
/// Does nothing (no dialog) if the needed device is not detected.
/// Prefer [markMediaGranted] after a real call-path getUserMedia that you keep.
Future<MediaPermissionStatus> requestMediaPermissions({
  bool camera = false,
}) =>
    impl.requestMediaPermissions(camera: camera);

/// Record that a live getUserMedia stream succeeded (call-path). Updates sticky
/// flags so call buttons show ready without a second probe that stops tracks.
void markMediaGranted({required bool mic, required bool camera}) =>
    impl.markMediaGranted(mic: mic, camera: camera);

/// Web: re-query when enumerateDevices fires `devicechange`.
void listenMediaDeviceChanges(void Function() onChange) =>
    impl.listenMediaDeviceChanges(onChange);

void cancelMediaDeviceChanges() => impl.cancelMediaDeviceChanges();
