#ifndef RUNNER_REMOTE_INPUT_PLUGIN_H_
#define RUNNER_REMOTE_INPUT_PLUGIN_H_

#include <flutter/flutter_view_controller.h>

// Registers MethodChannel "privet/remote_input" on the Flutter engine.
void RegisterRemoteInputPlugin(flutter::FlutterViewController* controller);

#endif  // RUNNER_REMOTE_INPUT_PLUGIN_H_
