Future<bool> requestNotificationPermission() async => false;

bool get notificationsGranted => false;

bool get documentHidden => false;

bool get documentHasFocus => true;

void showWebNotification({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
}) {}

/// No-op off web. Returns a disposer.
void Function() onDocumentVisible(void Function() callback) => () {};
