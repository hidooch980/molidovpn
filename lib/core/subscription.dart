import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server.dart';

/// The user's own subscription URLs: each body is cached in preferences and refreshed in the background.
class UserSubscriptions {
  static const _textPrefix = 'usub_text:', _timePrefix = 'usub_time:';

  /// Cached body per URL (URLs never fetched are missing).
  static Future<Map<String, String>> loadCached(List<String> urls) async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final url in urls) url: ?prefs.getString('$_textPrefix$url'),
    };
  }

  /// Downloads [url] (through [proxy] "host:port" when given) and caches the body when it has valid links.
  static Future<String> fetch(String url, {String? proxy}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      if (parseSubscription(text).isEmpty) throw const FormatException('no valid links');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_textPrefix$url', text);
      await prefs.setInt('$_timePrefix$url', DateTime.now().millisecondsSinceEpoch);
      return text;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> forget(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_textPrefix$url');
    await prefs.remove('$_timePrefix$url');
  }
}

/// Additional public profile feeds. They are deliberately separate from personal subscriptions
/// so users can audit, disable, and remove each source independently.
class PublicProfileSources {
  static const _textPrefix = 'public_feed_text:', _timePrefix = 'public_feed_time:';
  static const maxBodyChars = 2 * 1024 * 1024;

  static Future<Map<String, String>> loadCached(List<String> urls) async {
    final prefs = await SharedPreferences.getInstance();
    return {for (final url in urls) url: ?prefs.getString('$_textPrefix$url')};
  }

  static Future<String> fetch(String url, {String? proxy}) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || !(parsed.isScheme('http') || parsed.isScheme('https')) || parsed.host.isEmpty || parsed.userInfo.isNotEmpty) {
      throw const FormatException('Public source must be an HTTP(S) URL without embedded credentials');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final req = await client.getUrl(parsed);
      req.headers.set(HttpHeaders.acceptHeader, 'text/plain, application/octet-stream, */*');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      if (body.length > maxBodyChars) throw const FormatException('Source is larger than 2 MB');
      if (parseSubscription(body).isEmpty) throw const FormatException('No supported profile links found');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_textPrefix$url', body);
      await prefs.setInt('$_timePrefix$url', DateTime.now().millisecondsSinceEpoch);
      return body;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> forget(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_textPrefix$url');
    await prefs.remove('$_timePrefix$url');
  }
}

class SubscriptionData {
  const SubscriptionData(this.servers, this.updatedAt);

  final List<Server> servers;
  final DateTime updatedAt;
}

/// Downloads the tested server list from the vpn-sub repo, with CDN mirrors and an offline cache.
class SubscriptionRepository {
  /// Light list (40 servers) for iPhone/Hiddify — the full list can exceed iOS VPN memory limits.
  static const shareLink = 'https://raw.githubusercontent.com/hidooch980/vpn-sub/sub/lite_base64.txt';

  static const _mirrors = [
    // Static copy of the Worker's ranked catalog first; the Worker itself last (100k requests/day per account).
    'https://raw.githubusercontent.com/hidooch980/vpn-sub/sub/meta/catalog.txt',
    'https://cdn.jsdelivr.net/gh/hidooch980/vpn-sub@sub/meta/catalog.txt',
    'https://hidooch980.github.io/vpn-sub/sub.txt',
    'https://raw.githubusercontent.com/hidooch980/vpn-sub/sub/sub.txt',
    'https://cdn.jsdelivr.net/gh/hidooch980/vpn-sub@sub/sub.txt',
    'https://fastly.jsdelivr.net/gh/hidooch980/vpn-sub@sub/sub.txt',
    'https://cdn.jsdelivr.net/gh/hidooch980/vpn-sub@sub/sub_base64.txt',
    'https://molido-sub.hidooch980.workers.dev/',
  ];
  static const _textKey = 'sub_text', _timeKey = 'sub_time';

  Future<SubscriptionData?> loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(_textKey);
    final time = prefs.getInt(_timeKey);
    if (text == null || time == null) return null;
    final servers = await _parse(text);
    return servers.isEmpty ? null : SubscriptionData(servers, DateTime.fromMillisecondsSinceEpoch(time));
  }

  Future<SubscriptionData> fetch({String customUrl = ''}) async {
    for (final url in [if (customUrl.trim().isNotEmpty) customUrl.trim(), ..._mirrors]) {
      try {
        final text = await _get(url);
        final servers = await _parse(text);
        if (servers.isEmpty) continue;
        final now = DateTime.now();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_textKey, text);
        await prefs.setInt(_timeKey, now.millisecondsSinceEpoch);
        return SubscriptionData(servers, now);
      } catch (_) {
        continue;
      }
    }
    throw const SocketException('all subscription mirrors failed');
  }

  /// Parsing hundreds of links is heavy: do it off the UI isolate (falls back to inline parsing).
  static Future<List<Server>> _parse(String text) async {
    try {
      return await compute(parseSubscription, text);
    } catch (_) {
      return parseSubscription(text);
    }
  }

  Future<String> _get(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final bust = DateTime.now().millisecondsSinceEpoch ~/ 60000;
      final req = await client.getUrl(Uri.parse('$url?t=$bust'));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      return await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    } finally {
      client.close(force: true);
    }
  }
}
