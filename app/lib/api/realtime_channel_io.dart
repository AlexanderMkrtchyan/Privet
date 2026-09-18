import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens the realtime socket on native platforms with an OS-level keepalive.
///
/// `IOWebSocketChannel.connect` forwards `pingInterval` to `dart:io`'s
/// `WebSocket`, which sends RFC 6455 ping frames and — crucially — closes the
/// connection when a pong is missing. A half-open socket (idle NAT/proxy drop
/// with no FIN) therefore surfaces through `onDone` and reconnects, without
/// depending on the server answering an app-level heartbeat. Node's `ws`
/// answers protocol pings automatically.
WebSocketChannel connectRealtimeChannel(Uri uri) => IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 20),
    );
