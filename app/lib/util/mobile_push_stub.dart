Future<String?> registerMobilePushToken() async => null;

Future<void> attachMobilePushHandlers({
  required void Function(Map<String, String> data) onOpenPayload,
  void Function(String actionId, Map<String, String> data)? onAction,
}) async {}
