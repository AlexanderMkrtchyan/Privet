export 'web_notifications_stub.dart'
    if (dart.library.html) 'web_notifications_web.dart'
    if (dart.library.io) 'web_notifications_io.dart';
