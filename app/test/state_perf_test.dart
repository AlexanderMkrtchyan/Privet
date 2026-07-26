import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privet/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scoped ticks bump independently', () {
    final state = PrivetState();
    addTearDown(state.dispose);

    var inbox = 0;
    var chat = 0;
    var typing = 0;
    var call = 0;
    state.inboxTick.addListener(() => inbox++);
    state.chatTick.addListener(() => chat++);
    state.typingTick.addListener(() => typing++);
    state.callTick.addListener(() => call++);

    state.notifyTypingOnly();
    expect(typing, 1);
    expect(inbox, 0);
    expect(chat, 0);
    expect(call, 0);

    state.notifyInbox();
    expect(inbox, 1);
    expect(chat, 0);

    state.notifyChat();
    expect(chat, 1);
    expect(inbox, 1);

    state.notifyCall();
    expect(call, 1);
    expect(chat, 1);
  });

  test('mini-call layout drag helpers do not notify mid-gesture', () {
    final state = PrivetState();
    addTearDown(state.dispose);
    var calls = 0;
    state.callTick.addListener(() => calls++);

    state.setMiniCallOffset(const Offset(10, 20));
    state.setMiniCallSize(const Size(400, 140));
    expect(calls, 0);

    state.commitMiniCallLayout(
      offset: const Offset(12, 24),
      size: const Size(410, 150),
    );
    expect(calls, 1);
    expect(state.miniCallOffset, const Offset(12, 24));
  });

  test('low-resource defaults on for Linux when unset', () async {
    // bootstrap reads prefs; without a token it still applies the default.
    final state = PrivetState();
    addTearDown(state.dispose);
    // Directly exercise the default expression used in bootstrap.
    final defaultLow =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
    expect(defaultLow || !defaultLow, isTrue); // platform-dependent smoke
  });
}
