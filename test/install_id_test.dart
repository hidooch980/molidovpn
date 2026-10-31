import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/install_id.dart';

void main() {
  test('install ids are well formed, random and normalizable', () {
    final ids = List.generate(2000, (_) => InstallId.generate()).toSet();
    expect(ids.length, 2000);
    for (final id in ids) {
      expect(InstallId.valid(id), isTrue, reason: id);
    }
    expect(InstallId.valid('MLD-ABCI-0000'), isFalse);
    expect(InstallId.normalize(' mld 7k2m-9qxl '), 'MLD-7K2M-9QX1');
    expect(InstallId.normalize('MLD-123'), isNull);
  });

  test('diagnostics scrub configs, keys and addresses; ring buffer caps', () {
    final s = Diagnostics.scrub('vless://11111111-2222-3333-4444-555555555555@203.0.113.7:443?pbk=Ab#x '
        'token=secret at 198.51.100.23 ${'Q' * 40}');
    expect(s.contains('203.0.113.7'), isFalse);
    expect(s.contains('secret'), isFalse);
    expect(s.contains('555555555555'), isFalse);
    expect(s.contains('198.51.x.x'), isTrue);
    var lines = <String>[];
    for (var i = 0; i < Diagnostics.max + 10; i++) {
      lines = Diagnostics.append(lines, '$i');
    }
    expect(lines.length, Diagnostics.max);
    expect(lines.last, '${Diagnostics.max + 9}');
  });
}
