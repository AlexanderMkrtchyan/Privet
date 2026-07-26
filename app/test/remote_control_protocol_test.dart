import 'package:flutter_test/flutter_test.dart';
import 'package:privet/remote_control/protocol.dart';

void main() {
  group('RemoteControlProtocol.decode', () {
    test('accepts valid versioned messages', () {
      final msg = RemoteControlProtocol.decode(
        RemoteControlProtocol.pointerMove(x: 0.5, y: 0.25),
      );
      expect(msg, isNotNull);
      expect(msg!['t'], 'ptr');
      expect(msg['v'], kRemoteControlProtocolVersion);
      expect(msg['x'], 0.5);
      expect(msg['y'], 0.25);
    });

    test('rejects wrong version', () {
      expect(RemoteControlProtocol.decode('{"v":99,"t":"hb"}'), isNull);
    });

    test('rejects oversized payloads', () {
      final huge = '{"v":1,"t":"key","code":"${'A' * 70000}"}';
      expect(RemoteControlProtocol.decode(huge), isNull);
    });

    test('rejects malformed json', () {
      expect(RemoteControlProtocol.decode('not-json'), isNull);
      expect(RemoteControlProtocol.decode('[]'), isNull);
    });
  });

  group('letterbox mapping', () {
    test('maps center of contained 16:9 into 16:9 viewport', () {
      final p = RemoteControlProtocol.mapLetterboxedPoint(
        localX: 400,
        localY: 225,
        viewportWidth: 800,
        viewportHeight: 450,
        contentAspect: 16 / 9,
      );
      expect(p, isNotNull);
      expect(p!.x, closeTo(0.5, 0.01));
      expect(p.y, closeTo(0.5, 0.01));
    });

    test('clamps letterbox gutters to content edges (dock / top bar)', () {
      final p = RemoteControlProtocol.mapLetterboxedPoint(
        localX: 10,
        localY: 10,
        viewportWidth: 800,
        viewportHeight: 800,
        contentAspect: 16 / 9,
      );
      expect(p, isNotNull);
      expect(p!.x, closeTo(0.0, 0.02));
      expect(p.y, closeTo(0.0, 0.02));
    });
  });

  group('RemoteControlSessionState', () {
    test('blocks host events until granted', () {
      final s = RemoteControlSessionState();
      expect(s.acceptHostEvent(DateTime.now()), isFalse);
      s.markGranted(asController: false);
      expect(s.acceptHostEvent(DateTime.now()), isTrue);
    });

    test('rate limits host events', () {
      final s = RemoteControlSessionState()..markGranted(asController: false);
      final now = DateTime.now();
      var accepted = 0;
      for (var i = 0; i < kRemoteControlMaxEventsPerSecond + 40; i++) {
        if (s.acceptHostEvent(now)) accepted++;
      }
      expect(accepted, kRemoteControlMaxEventsPerSecond);
    });

    test('force accepts bypass rate limit (key/button ups)', () {
      final s = RemoteControlSessionState()..markGranted(asController: false);
      final now = DateTime.now();
      for (var i = 0; i < kRemoteControlMaxEventsPerSecond; i++) {
        expect(s.acceptHostEvent(now), isTrue);
      }
      expect(s.acceptHostEvent(now), isFalse);
      expect(s.acceptHostEvent(now, force: true), isTrue);
    });

    test('revoke clears grant', () {
      final s = RemoteControlSessionState()..markGranted(asController: true);
      expect(s.isController, isTrue);
      s.markRevoked();
      expect(s.isGranted, isFalse);
      expect(s.role, RemoteControlRole.none);
    });

    test('heartbeat expiry', () {
      final s = RemoteControlSessionState()..markGranted(asController: false);
      s.lastHeartbeatAt = DateTime.now().subtract(const Duration(seconds: 30));
      expect(s.heartbeatExpired(), isTrue);
      s.noteHeartbeat();
      expect(s.heartbeatExpired(), isFalse);
    });
  });

  group('encode helpers', () {
    test('clamps pointer coords', () {
      final msg = RemoteControlProtocol.decode(
        RemoteControlProtocol.pointerMove(x: 2, y: -1),
      )!;
      expect(msg['x'], 1.0);
      expect(msg['y'], 0.0);
    });

    test('key and release round-trip', () {
      final key = RemoteControlProtocol.decode(
        RemoteControlProtocol.keyEvent(code: 'KeyA', down: true, mods: 2),
      )!;
      expect(key['t'], 'key');
      expect(key['code'], 'KeyA');
      expect(key['mods'], 2);
      final rel = RemoteControlProtocol.decode(RemoteControlProtocol.releaseAll())!;
      expect(rel['t'], 'release');
    });
  });

  group('remoteControlUnavailableReason', () {
    test('blames browser only for web hosts', () {
      expect(
        remoteControlUnavailableReason(
          peerShareControllable: false,
          peerPlatform: 'web',
        ),
        contains('browser'),
      );
    });

    test('surfaces native host detail instead of browser', () {
      final reason = remoteControlUnavailableReason(
        peerShareControllable: false,
        peerPlatform: 'linux',
        peerDetail: 'Wayland RemoteDesktop portal is unavailable on this compositor.',
      );
      expect(reason, isNot(contains('browser')));
      expect(reason, contains('Wayland RemoteDesktop portal'));
    });

    test('returns empty when controllable', () {
      expect(
        remoteControlUnavailableReason(peerShareControllable: true),
        '',
      );
    });
  });

  group('remoteControlDeniedReason', () {
    test('uses peer reason when present', () {
      expect(
        remoteControlDeniedReason('Could not enable OS input: portal'),
        'Could not enable OS input: portal',
      );
    });

    test('falls back without blaming browser', () {
      final reason = remoteControlDeniedReason(null);
      expect(reason, 'Remote control was denied.');
      expect(reason, isNot(contains('browser')));
    });
  });

  group('remoteControlHostCannotInjectMessage', () {
    test('web mentions browser tab', () {
      expect(
        remoteControlHostCannotInjectMessage(platform: 'web', detail: ''),
        contains('browser tab'),
      );
    });

    test('native does not mention browser', () {
      final msg = remoteControlHostCannotInjectMessage(
        platform: 'windows',
        detail: 'Native remote-input plugin is not registered.',
      );
      expect(msg, isNot(contains('browser')));
      expect(msg, contains('plugin is not registered'));
    });
  });
}
