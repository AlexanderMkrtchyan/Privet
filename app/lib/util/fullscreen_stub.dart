import 'package:flutter/services.dart';

bool _fullscreen = false;

Future<void> enterFullscreen() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  _fullscreen = true;
}

Future<void> exitFullscreen() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  _fullscreen = false;
}

bool isFullscreen() => _fullscreen;
