import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// `version.json` on the vpn-sub `live` branch: one hash per part an app may need to refetch.
/// Empty hash = unknown (the publisher could not read it); never counts as a change.
class LiveVersion {
  const LiveVersion({
    required this.v,
    this.flags = '',
    this.notice = '',
    this.release = '',
    this.critical = false,
    this.resilience = '',
    this.catalog = '',
  });

  final String v, flags, notice, release, resilience, catalog;
  final bool critical;

  static LiveVersion? parse(String? text) {
    try {
      final o = jsonDecode(text ?? '') as Map<String, dynamic>;
      final v = '${o['v'] ?? ''}';
      if (v.isEmpty) return null;
      String s(String k) => '${o[k] ?? ''}';
      return LiveVersion(
        v: v,
        flags: s('flags'),
        notice: s('notice'),
        release: s('release'),
        critical: o['critical'] == true,
        resilience: s('resilience'),
        catalog: s('catalog'),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'v': v,
    'flags': flags,
    'notice': notice,
    'release': release,
    'critical': critical,
    'resilience': resilience,
    'catalog': catalog,
  };

  /// Parts whose hash moved ('flags', 'notice', 'release', 'catalog'). No previous copy: all known parts.
  static Set<String> changes(LiveVersion? old, LiveVersion fresh) {
    if (old != null && old.v == fresh.v) return {};
    bool moved(String? o, String n) => n.isNotEmpty && o != n;
    return {
      if (moved(old?.flags, fresh.flags)) 'flags',
      if (moved(old?.notice, fresh.notice)) 'notice',
      if (moved(old?.release, fresh.release)) 'release',
      if (moved(old?.catalog, fresh.catalog)) 'catalog',
    };
  }
}

/// Cheap change check without the Cloudflare Worker: GitHub raw, then jsDelivr, with ETag (a 304 when
/// nothing moved). Called on window focus, after connecting and every 10 min while the app runs.
class LiveSync {
  static const raw = 'https://raw.githubusercontent.com/hidooch980/vpn-sub/live';
  static const cdn = 'https://cdn.jsdelivr.net/gh/hidooch980/vpn-sub@live';
  static const _key = 'live_version';
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _busy = false;
  static LiveVersion? current;

  /// Changed parts ({} when unchanged, throttled or offline). Never throws.
  static Future<Set<String>> check({String? proxy, String reason = ''}) async {
    final now = DateTime.now();
    if (_busy || now.difference(_last) < const Duration(seconds: 45)) return {};
    _busy = true;
    _last = now;
    try {
      final prefs = await SharedPreferences.getInstance();
      current ??= LiveVersion.parse(prefs.getString(_key));
      for (final base in const [raw, cdn]) {
        final etagKey = 'live_etag_$base';
        final r = await _get('$base/version.json', prefs.getString(etagKey), proxy);
        if (r == null) continue;
        if (r.$1 == 304) return {};
        final fresh = LiveVersion.parse(r.$2);
        if (fresh == null) continue;
        if (r.$3 != null) await prefs.setString(etagKey, r.$3!);
        final parts = LiveVersion.changes(current, fresh);
        current = fresh;
        await prefs.setString(_key, jsonEncode(fresh.toJson()));
        if (parts.isNotEmpty) AppLog.add('live: ${parts.join(', ')} changed ($reason)');
        return parts;
      }
      return {};
    } catch (_) {
      return {};
    } finally {
      _busy = false;
    }
  }

  static Future<(int, String?, String?)?> _get(String url, String? etag, String? proxy) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'MolidoVPN-Windows');
      if (etag != null) req.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 304) {
        await res.drain<void>();
        return (304, null, etag);
      }
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      return (200, body, res.headers.value(HttpHeaders.etagHeader));
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
