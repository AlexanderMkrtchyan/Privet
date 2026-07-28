import 'agent_debug_log_stub.dart'
    if (dart.library.io) 'agent_debug_log_io.dart' as impl;

/// Session debug NDJSON logger (debug mode 32b317).
void agentDebugLog({
  required String hypothesisId,
  required String location,
  required String message,
  Map<String, Object?> data = const {},
  String runId = 'pre',
}) {
  impl.agentDebugLog(
    hypothesisId: hypothesisId,
    location: location,
    message: message,
    data: data,
    runId: runId,
  );
}

void agentDebugInstallFrameProbe() => impl.agentDebugInstallFrameProbe();

void agentDebugSetHasCall(bool v) => impl.agentDebugSetHasCall(v);

void agentDebugCountNotify(String kind) => impl.agentDebugCountNotify(kind);

void agentDebugIBeamRebuild() => impl.agentDebugIBeamRebuild();
