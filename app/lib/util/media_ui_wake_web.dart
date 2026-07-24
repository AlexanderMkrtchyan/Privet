// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

import 'package:flutter/scheduler.dart';

/// Browser permission / getUserMedia dialogs often leave Flutter web without
/// frames or pointer events until a resize/focus. Kick the engine after Allow.
void wakeUiAfterMediaDialog() {
  try {
    html.window.dispatchEvent(html.Event('resize'));
  } catch (_) {}
  try {
    // dart:html Window.focus() is missing on some SDKs; keep the wake kick.
    (html.window as dynamic).focus();
  } catch (_) {}
  try {
    SchedulerBinding.instance.scheduleForcedFrame();
    SchedulerBinding.instance.ensureVisualUpdate();
  } catch (_) {}
}
