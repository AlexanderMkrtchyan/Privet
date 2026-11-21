import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privet/api/realtime.dart';

/// Minimal Privet `/ws` stand-in: answers `auth` with `auth.ok`, `ping` with
/// `pong`, and records what the client sends.
class FakeWsServer {
  FakeWsServer._(this._server) {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      connections++;
      _sockets.add(socket);
      socket.listen(
        (raw) {
          final Map<String, dynamic> msg;
          try {
            msg = jsonDecode(raw as String) as Map<String, dynamic>;
          } catch (_) {
            return;
          }
          received.add(msg);
          if (socket.readyState != WebSocket.open) return;
          try {
            switch (msg['type']) {
              case 'auth':
                authCount++;
                socket.add(jsonEncode({'type': 'auth.ok', 'userId': 'u1'}));
              case 'ping':
                if (answerPing) socket.add(jsonEncode({'type': 'pong'}));
            }
          } catch (_) {
            // The peer closed while we were answering — expected on reconnect.
          }
        },
        onDone: () => _sockets.remove(socket),
        onError: (Object _) => _sockets.remove(socket),
      );
    });
  }

  final HttpServer _server;
  final List<WebSocket> _sockets = [];

  /// Every frame the client sent, in order.
  final List<Map<String, dynamic>> received = [];

  /// Every accepted TCP/WS connection, including replacements after drop.
  int connections = 0;

  /// `auth` frames seen (one per successful reconnect).
  int authCount = 0;

  /// When false the server keeps the socket open but never answers, i.e. the
  /// half-open NAT/proxy corpse that mobile networks produce.
  bool answerPing = true;

  String get url => 'ws://${_server.address.address}:${_server.port}/ws';

  List<WebSocket> get sockets => List<WebSocket>.unmodifiable(_sockets);

  static Future<FakeWsServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return FakeWsServer._(server);
  }

  Future<void> closeLatest() async {
    if (_sockets.isEmpty) return;
    await _sockets.last.close();
  }

  Future<void> close() async {
    for (final socket in [..._sockets]) {
      try {
        await socket.close();
      } catch (_) {}
    }
    await _server.close(force: true);
  }
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 6),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within ${timeout.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('a burst of resume reconnects opens exactly one socket', () async {
    final server = await FakeWsServer.start();
    final client = RealtimeClient(url: server.url);
    addTearDown(() async {
      await client.disconnect();
      await server.close();
    });

    // Android can fire resumed several times for one return to foreground.
    await Future.wait([
      client.ensureConnected('t', force: true),
      client.ensureConnected('t', force: true),
      client.ensureConnected('t', force: true),
      client.ensureConnected('t', force: true),
      client.ensureConnected('t', force: true),
    ]);
    await waitFor(() => server.authCount == 1);

    expect(server.connections, 1,
        reason: 'back-to-back forced resumes must coalesce');

    // The surviving socket must be a working, fully wired one.
    client.sendMessage(conversationId: 'c1', body: 'after resume storm');
    await waitFor(() => server.received.any((m) => m['type'] == 'message.send'));
    expect(
      server.received.firstWhere((m) => m['type'] == 'message.send')['body'],
      'after resume storm',
    );
  });

  test('a dropped socket is reopened and reports one reconnect', () async {
    final server = await FakeWsServer.start();
    final client = RealtimeClient(url: server.url);
    addTearDown(() async {
      await client.disconnect();
      await server.close();
    });
    final events = <Map<String, dynamic>>[];
    client.addHandler(events.add);
    var reconnects = 0;
    client.onReconnected = () => reconnects++;

    await client.connect('t');
    await waitFor(() => server.authCount == 1);
    expect(reconnects, 0, reason: 'the first connect is not a reconnect');

    await server.closeLatest();
    await waitFor(() => server.connections >= 2);
    await waitFor(() => reconnects == 1);

    // Events on the replacement socket must still reach the listener.
    server.sockets.last.add(jsonEncode({'type': 'message', 'id': 'm1'}));
    await waitFor(() => events.any((e) => e['type'] == 'message'));
  });

  test('ensureConnected never throws when the server is gone', () async {
    final server = await FakeWsServer.start();
    final client = RealtimeClient(url: server.url);
    addTearDown(() async {
      await client.disconnect();
      await server.close();
    });

    await server.close();
    // Must resolve (and keep retrying in the background), not propagate an
    // error into onAppResumed — that used to skip the whole resume resync.
    await client.ensureConnected('t', force: true).timeout(
          const Duration(seconds: 3),
        );
  });

  test('a silently dead socket is detected by the heartbeat', () async {
    final server = await FakeWsServer.start();
    final client = RealtimeClient(
      url: server.url,
      heartbeatInterval: const Duration(milliseconds: 120),
      staleAfter: const Duration(milliseconds: 250),
    );
    addTearDown(() async {
      await client.disconnect();
      await server.close();
    });

    await client.connect('t');
    await waitFor(() => server.authCount == 1);

    // Socket stays "open" but nothing comes back — the mobile half-open case.
    server.answerPing = false;
    await waitFor(() => server.connections >= 2);
    // The replacement socket must authenticate too, or it is just another
    // half-open corpse the app would keep talking to.
    await waitFor(() => server.authCount >= 2);
  });
}
