import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/updater.dart';

const _assetName = 'MolidoVPN-android-universal.apk';
const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, dynamic> _release({
  String tag = 'v4.0.10',
  String? url,
  String? digest = 'sha256:$_sha',
  int size = 120000000,
}) => {
  'tag_name': tag,
  'body': 'release notes',
  'assets': [
    {
      'name': _assetName,
      'browser_download_url': url ??
          'https://github.com/hidooch980/molidovpn/releases/download/$tag/$_assetName',
      'size': size,
      if (digest != null) 'digest': digest,
    },
  ],
};

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

  group('Updater.parseRelease integrity checks', () {
    test('accepts the exact trusted asset with bounded size and SHA-256', () {
      final update = Updater.parseRelease(_release(), _assetName);
      expect(update, isNotNull);
      expect(update!.version, '4.0.10');
      expect(update.size, 120000000);
      expect(update.sha256, _sha);
      expect(update.url, 'https://github.com/hidooch980/molidovpn/releases/download/v4.0.10/$_assetName');
    });

    test('rejects a missing or malformed SHA-256 digest', () {
      expect(Updater.parseRelease(_release(digest: null), _assetName), isNull);
      expect(Updater.parseRelease(_release(digest: 'sha256:bad'), _assetName), isNull);
    });

    test('rejects untrusted hosts and paths', () {
      expect(
        Updater.parseRelease(_release(url: 'https://evil.example/releases/download/v4.0.10/$_assetName'), _assetName),
        isNull,
      );
      expect(
        Updater.parseRelease(
          _release(url: 'https://github.com/attacker/molidovpn/releases/download/v4.0.10/$_assetName'),
          _assetName,
        ),
        isNull,
      );
    });

    test('rejects malformed tags and unreasonable asset sizes', () {
      expect(Updater.parseRelease(_release(tag: 'v4.x.10'), _assetName), isNull);
      expect(Updater.parseRelease(_release(size: 0), _assetName), isNull);
      expect(Updater.parseRelease(_release(size: 600 * 1024 * 1024), _assetName), isNull);
    });
  });
}
