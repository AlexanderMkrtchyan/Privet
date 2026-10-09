import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/mobile_push_notifications.dart';

void main() {
  test('androidNotificationId matches Java String.hashCode', () {
    expect(androidNotificationId('a'), 97);
    expect(androidNotificationId('chat:abc'), 1436613952);
    expect(androidNotificationId('chat:conv-1'), 1034329658);
  });
}
