import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/live_sync.dart';
import 'package:mobin_vpn/core/updater.dart';

void main() {
  test('only moved parts count; empty hash is unknown', () {
    const a = LiveVersion(v: '1', flags: 'f1', notice: 'n1', release: 'v3.2.1', catalog: 'c1');
    expect(LiveVersion.changes(null, a), {'flags', 'notice', 'release', 'catalog'});
    expect(LiveVersion.changes(a, a), isEmpty);
    const b = LiveVersion(v: '2', flags: 'f2', notice: 'n1', release: 'v3.2.1', catalog: 'c1');
    expect(LiveVersion.changes(a, b), {'flags'});
    const c = LiveVersion(v: '3', flags: '', notice: 'n1', release: 'v3.2.1', catalog: 'c1');
    expect(LiveVersion.changes(a, c), isEmpty);
    expect(LiveVersion.parse('{"v":"9","release":"v1","critical":true}')!.critical, isTrue);
    expect(LiveVersion.parse('{}'), isNull);
  });

  test('release parsing: sha256 from digest, critical from body or flag', () {
    final json = {
      'tag_name': 'v3.2.200',
      'body': 'Fixes [CRITICAL] issue',
      'assets': [
        {'name': 'MolidoVPN-windows-setup.exe', 'size': 5, 'browser_download_url': 'https://x/s.exe', 'digest': 'sha256:${'a' * 64}'},
      ],
    };
    final u = Updater.parseRelease(json, 'MolidoVPN-windows-setup.exe')!;
    expect(u.version, '3.2.200');
    expect(u.sha256, 'a' * 64);
    expect(u.critical, isTrue);
    expect(Updater.parseRelease({...json, 'body': ''}, 'MolidoVPN-windows-setup.exe')!.critical, isFalse);
    expect(Updater.parseRelease({...json, 'body': '', 'critical': true}, 'MolidoVPN-windows-setup.exe')!.critical, isTrue);
    expect(Updater.parseRelease(json, 'other.exe'), isNull);
  });

  test('update sources: GitHub copies before the Worker', () {
    expect(Updater.sources.first, startsWith('https://raw.githubusercontent.com/'));
    expect(Updater.sources.last, contains('workers.dev'));
  });
}
