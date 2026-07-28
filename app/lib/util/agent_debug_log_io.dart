/// Production no-op. Session debug probes (8ms event-loop timer + frame
/// windows + append to `.cursor/debug-*.log`) were starving the UI isolate
/// and freezing the Linux app after the screenshare work. Keep the API so
/// call sites compile; do not re-enable disk logging in shipped builds.

void agentDebugLog({
  required String hypothesisId,
  required String location,
  required String message,
  Map<String, Object?> data = const {},
  String runId = '',
}) {}

void agentDebugInstallFrameProbe() {}

void agentDebugSetHasCall(bool v) {}

void agentDebugCountNotify(String kind) {}

void agentDebugIBeamRebuild() {}
