import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/app_log.dart';

void main() {
  setUp(AppLog.clear);

  test('shareable diagnostics redact credentials, profiles, emails and IPv4', () {
    AppLog.add('Authorization: Bearer bearer-secret');
    AppLog.add('password="two words secret" access_token=access-secret');
    AppLog.add('support.person@example.com 203.0.113.42');
    AppLog.add('vless://profile-user:profile-secret@edge.example:443?token=profile-token');

    final output = AppLog.dump();

    for (final secret in [
      'bearer-secret',
      'two words secret',
      'access-secret',
      'support.person@example.com',
      '203.0.113.42',
      'profile-user',
      'profile-secret',
      'profile-token',
    ]) {
      expect(output, isNot(contains(secret)));
    }
    expect(output, contains('[redacted]'));
    expect(output, contains('[email]'));
    expect(output, contains('[ip]'));
    expect(output, contains('[vpn-profile]'));
  });

  test('keeps actionable error context', () {
    AppLog.add('TLS handshake failed after 2500ms with HTTP 503');
    final output = AppLog.dump();
    expect(output, contains('TLS handshake failed'));
    expect(output, contains('2500ms'));
    expect(output, contains('HTTP 503'));
  });

  test('retains the bounded ring buffer behavior', () {
    for (var i = 0; i < 510; i++) {
      AppLog.add('diagnostic $i');
    }
    final lines = AppLog.dump().split('\n');
    expect(lines, hasLength(500));
    expect(lines.first, contains('diagnostic 10'));
    expect(lines.last, contains('diagnostic 509'));
  });
}
