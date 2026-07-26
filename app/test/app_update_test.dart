import 'package:flutter_test/flutter_test.dart';
import 'package:privet/util/app_update.dart';

void main() {
  group('compareAppVersions', () {
    test('compares dotted versions', () {
      expect(compareAppVersions('0.1.3', '4', '0.1.8', '5'), lessThan(0));
      expect(compareAppVersions('0.1.8', '5', '0.1.3', '4'), greaterThan(0));
      expect(compareAppVersions('1.0.0', '1', '1.0.0', '1'), 0);
    });

    test('uses build number as tiebreaker', () {
      expect(compareAppVersions('0.1.8', '4', '0.1.8', '5'), lessThan(0));
      expect(compareAppVersions('0.1.8', '10', '0.1.8', '9'), greaterThan(0));
    });

    test('handles uneven part lengths', () {
      expect(compareAppVersions('0.2', '0', '0.1.9', '0'), greaterThan(0));
      expect(compareAppVersions('0.1.9', '0', '0.2', '0'), lessThan(0));
    });
  });

  group('AppReleaseInfo', () {
    test('parses flat and nested download urls', () {
      final info = AppReleaseInfo.fromJson({
        'version': '0.1.8',
        'build_number': '5',
        'windows_setup_url': '/downloads/Privet-Setup.exe',
        'linux': {
          'deb_url': '/downloads/privet-linux-amd64.deb',
          'tar_url': '/downloads/privet-linux-x64.tar.gz',
        },
      });
      expect(info.version, '0.1.8');
      expect(info.buildNumber, '5');
      expect(info.windowsSetupUrl, '/downloads/Privet-Setup.exe');
      expect(info.linuxDebUrl, '/downloads/privet-linux-amd64.deb');
      expect(info.linuxTarUrl, '/downloads/privet-linux-x64.tar.gz');
    });
  });
}
