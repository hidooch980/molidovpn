import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'smart/smart_connect.dart';

import 'app_log.dart';

/// One announcement from the owner panel (/app/notice.json).
class AppNotice {
  const AppNotice({required this.id, required this.text, required this.warning, required this.link, required this.linkLabel});

  final String id, text, link, linkLabel;
  final bool warning;
}

/// Owner-controlled settings from the /admin panel: disabled connection modes, default mode and the
/// home-screen announcement. Fails safe: fetched copy, else last cached copy, else defaults (all enabled, auto).
class RemoteConfig {
  static const _base = 'https://molido-sub.hidooch980.workers.dev/app';
  static const _flagsKey = 'remote_flags', _noticeKey = 'remote_notice', _dismissedKey = 'remote_notice_dismissed';

  /// Route keys the panel can switch off (Windows routes use warp, amnezia, psiphon, tor, dns, v2ray).
  static const known = {'warp', 'masque', 'gool', 'amnezia', 'psiphon', 'tor', 'dns', 'shard', 'v2ray'};

  static Set<String> disabled = {};
  static String defaultMode = 'auto';

  /// Smart Connect limits from flags.json "smart" (defaults when absent or invalid).
  static SmartConfig smart = const SmartConfig();
  static AppNotice? notice;
  static DateTime? _fetchedAt;

  static bool isDisabled(String route) => disabled.contains(route);

  /// Loads the cached copy (fast, no network).
  static Future<void> loadCached() async {
    try {
      final p = await SharedPreferences.getInstance();
      _applyFlags(p.getString(_flagsKey));
      _applyNotice(p.getString(_noticeKey), p.getString(_dismissedKey));
    } catch (_) {}
  }

  /// Fetches both files (at most every 5 minutes unless [force]); returns true when something changed.
  static Future<bool> refresh({String? proxy, bool force = false}) async {
    final at = _fetchedAt;
    if (!force && at != null && DateTime.now().difference(at) < const Duration(minutes: 5)) return false;
    final before = '${disabled.toList()..sort()}|$defaultMode|${notice?.id}';
    final flags = await _get('flags.json', proxy);
    final noticeBody = await _get('notice.json', proxy);
    try {
      final p = await SharedPreferences.getInstance();
      if (flags != null && _applyFlags(flags)) await p.setString(_flagsKey, flags);
      if (noticeBody != null) {
        await p.setString(_noticeKey, noticeBody);
        _applyNotice(noticeBody, p.getString(_dismissedKey));
      }
    } catch (_) {}
    if (flags != null || noticeBody != null) _fetchedAt = DateTime.now();
    return before != '${disabled.toList()..sort()}|$defaultMode|${notice?.id}';
  }

  static Future<void> dismissNotice() async {
    final id = notice?.id;
    notice = null;
    if (id == null) return;
    try {
      await (await SharedPreferences.getInstance()).setString(_dismissedKey, id);
    } catch (_) {}
  }

  static bool _applyFlags(String? body) {
    if (body == null) return false;
    try {
      final json = jsonDecode(body);
      if (json is! Map) return false;
      final raw = json['disabled'];
      final off = <String>{
        if (raw is List)
          for (final m in raw)
            if (m is String && known.contains(m)) m,
      };
      // Never all modes off, whatever arrives.
      disabled = off.length >= known.length ? {} : off;
      final def = json['default_mode'];
      defaultMode = def is String && known.contains(def) && !disabled.contains(def) ? def : 'auto';
      smart = SmartConfig.fromJson(json['smart']);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void _applyNotice(String? body, String? dismissed) {
    notice = null;
    if (body == null) return;
    try {
      final json = jsonDecode(body);
      if (json is! Map) return;
      final id = json['id'], text = json['text'];
      if (id is! String || id.isEmpty || text is! String || text.trim().isEmpty || id == dismissed) return;
      final exp = json['expires_at'];
      if (exp is num && exp > 0 && exp <= DateTime.now().millisecondsSinceEpoch) return;
      final link = json['link'];
      final label = json['link_label'];
      notice = AppNotice(
        id: id,
        text: text.trim(),
        warning: json['type'] == 'warning',
        link: link is String && link.startsWith('https://') ? link : '',
        linkLabel: label is String ? label.trim() : '',
      );
    } catch (_) {}
  }

  /// Static copies (vpn-sub `meta/`, mirrored every ~15 min) first; the Worker last.
  static Future<String?> _get(String file, String? proxy) async {
    for (final base in const [
      'https://raw.githubusercontent.com/hidooch980/vpn-sub/sub/meta',
      'https://cdn.jsdelivr.net/gh/hidooch980/vpn-sub@sub/meta',
      _base,
    ]) {
      final body = await _getFrom('$base/$file', proxy);
      if (body != null && body.trimLeft().startsWith('{')) return body;
    }
    return null;
  }

  static Future<String?> _getFrom(String url, String? proxy) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
      return body.length < 16000 ? body : null;
    } catch (e) {
      AppLog.add('remote config: $url not fetched ($e)');
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
