import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens the realtime socket for non-IO platforms (web).
///
/// The browser owns keepalive/ping, so no `pingInterval` is available here —
/// [RealtimeClient] keeps the link warm with an app-level ping/pong instead.
WebSocketChannel connectRealtimeChannel(Uri uri) =>
    WebSocketChannel.connect(uri);
