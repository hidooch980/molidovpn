import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/updater.dart';

void main() {
  group('Updater.parseRedirectTag', () {
    test('accepts GitHub latest release redirects with and without v prefix', () {
      expect(Updater.parseRedirectTag('https://github.com/hidooch980/molidovpn/releases/tag/v4.0.9'), 'v4.0.9');
      expect(Updater.parseRedirectTag('https://github.com/hidooch980/molidovpn/releases/tag/4.1.0'), '4.1.0');
    });

    test('rejects non-release and malformed redirects', () {
      expect(Updater.parseRedirectTag('https://github.com/hidooch980/molidovpn/releases/latest'), isNull);
      expect(Updater.parseRedirectTag('https://attacker.example/tag/v4.0.9'), isNull);
      expect(Updater.parseRedirectTag('https://github.com/hidooch980/molidovpn/releases/tag/v4.x.9'), isNull);
    });
  });
}
