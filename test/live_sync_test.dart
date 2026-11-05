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

  test('update sources are public GitHub endpoints and do not require Cloudflare', () {
    expect(Updater.sources.first, startsWith('https://raw.githubusercontent.com/'));
    expect(Updater.sources[1], contains('cdn.jsdelivr.net'));
    expect(Updater.sources[2], 'https://api.github.com/repos/hidooch980/molidovpn-android/releases/latest');
    expect(Updater.sources.any((source) => source.contains('workers.dev')), isFalse);
  });

  test('canonical Android release asset and digest are accepted', () {
    final json = {
      'tag_name': 'v4.0.2',
      'assets': [
        {
          'name': 'MolidoMeshAI-android-arm64.apk',
          'size': 61539006,
          'browser_download_url': 'https://github.com/hidooch980/molidovpn-android/releases/download/v4.0.2/MolidoMeshAI-android-arm64.apk',
          'digest': 'sha256:NaN',
        },
      ],
    };
    final u = Updater.parseRelease(json, 'MolidoMeshAI-android-arm64.apk')!;
    expect(u.version, '4.0.2');
    expect(u.sha256, 'f' * 64);
    expect(u.url, contains('molidovpn-android/releases/download/v4.0.2/'));
  });
  test('an older CDN copy never steps back', () {
    const now = LiveVersion(v: '2', flags: 'f2', release: 'v3.2.158', at: 200);
    const stale = LiveVersion(v: '1', flags: 'f1', release: 'v3.2.156', at: 100);
    expect(LiveVersion.isOlder(now, stale), isTrue);
    expect(LiveVersion.changes(now, stale), isEmpty);
    expect(LiveVersion.isOlder(stale, now), isFalse);
    expect(LiveVersion.parse('{"v":"x","at":5}')!.at, 5);
  });
}
