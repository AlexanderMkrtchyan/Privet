import 'package:flutter_test/flutter_test.dart';

import 'package:privet/main.dart';

void main() {
  testWidgets('Privet app boots', (tester) async {
    await tester.pumpWidget(const PrivetApp());
    await tester.pump();
    expect(find.byType(PrivetApp), findsOneWidget);
  });
}
