import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server.dart';

/// The user's own subscription URLs: each body is cached in preferences and refreshed in the background.
class UserSubscriptions {
  static const maxBodyBytes = 2 * 1024 * 1024;
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
      if (res.contentLength > maxBodyBytes) throw const FormatException('Subscription is larger than 2 MB');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > maxBodyBytes) {
          throw const FormatException('Subscription is larger than 2 MB');
        }
        bytes.add(chunk);
      }
      final text = utf8.decode(bytes.takeBytes());
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
  static const maxBodyBytes = 2 * 1024 * 1024;

  static Future<Map<String, String>> loadCached(List<String> urls) async {
    final prefs = await SharedPreferences.getInstance();
    return {for (final url in urls) url: ?prefs.getString('$_textPrefix$url')};
  }

  /// Reject loopback, private, link-local, multicast, reserved and documentation IP ranges.
  /// Redirects are disabled below so a validated public URL cannot redirect to a private target.
  static bool _isPublicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = b[0], c = b[1];
      if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
      if (a == 169 && c == 254) return false;
      if (a == 172 && c >= 16 && c <= 31) return false;
      // Exact special-use blocks: 192.0.0/24, 192.0.2/24,
      // 192.88.99/24 (6to4 relay anycast), and private 192.168/16.
      if (a == 192 && (
          (c == 0 && (b[2] == 0 || b[2] == 2)) ||
          (c == 88 && b[2] == 99) ||
          c == 168
      )) {
        return false;
      }
      if (a == 100 && c >= 64 && c <= 127) return false;
      if (a == 198 && (c == 18 || c == 19 || (c == 51 && b[2] == 100))) return false;
      if (a == 203 && c == 0 && b[2] == 113) return false;
      return true;
    }
    // IPv4-mapped IPv6: apply the IPv4 policy to the embedded address.
    if (b.length == 16 && b.take(10).every((v) => v == 0) && b[10] == 255 && b[11] == 255) {
      return _isPublicAddress(InternetAddress.fromRawAddress(b.sublist(12)));
    }
    // Permit only global-unicast 2000::/3. Reject special-use transition,
    // documentation and benchmarking ranges conservatively.
    if (b.length != 16 || (b[0] & 0xe0) != 0x20) return false;
    if (b[0] == 0x20 && b[1] == 0x01) {
      if (b[2] == 0x0d && b[3] == 0xb8) return false; // 2001:db8::/32
      if ((b[2] & 0xfe) == 0x00) return false; // 2001::/23
    }
    if (b[0] == 0x20 && b[1] == 0x02) return false; // 6to4
    if (b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0x00) return false; // 3fff::/20 docs
    return true;
  }

  static Future<List<InternetAddress>> _validatePublicDestination(Uri uri) async {
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = literal == null
        ? await InternetAddress.lookup(uri.host).timeout(const Duration(seconds: 10))
        : <InternetAddress>[literal];
    if (addresses.isEmpty || addresses.any((address) => !_isPublicAddress(address))) {
      throw const FormatException('Public source host resolves to a non-public IP address');
    }
    return List<InternetAddress>.unmodifiable(addresses);
  }

  static Future<String> fetch(String url, {String? proxy}) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || !(parsed.isScheme('http') || parsed.isScheme('https')) ||
        parsed.host.isEmpty || parsed.userInfo.isNotEmpty) {
      throw const FormatException('Public source must be an HTTP(S) URL without embedded credentials');
    }
    if (parsed.hasPort && (parsed.port < 1 || parsed.port > 65535)) {
      throw const FormatException('Invalid public source port');
    }
    if (proxy != null && proxy.trim().isNotEmpty) {
      throw const FormatException(
        'Public feeds cannot use an unpinned proxy; disable the proxy or use a direct network connection',
      );
    }
    // Resolve once, reject every non-public answer, and pin the actual TCP
    // connection to one of those validated addresses. The URI hostname remains
    // unchanged so HttpClient still sends the correct Host header and verifies
    // TLS certificates/SNI against the hostname. Proxies are intentionally
    // disabled because a proxy would perform its own unpinned destination lookup.
    final addresses = await _validatePublicDestination(parsed);
    var nextAddress = 0;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (proxyHost != null || proxyPort != null ||
          uri.host.toLowerCase() != parsed.host.toLowerCase() ||
          uri.port != parsed.port) {
        throw const FormatException('Public source connection target changed');
      }
      Object? lastError;
      for (var attempt = 0; attempt < addresses.length; attempt++) {
        final address = addresses[nextAddress++ % addresses.length];
        try {
          final task = await Socket.startConnect(address, uri.port);
          try {
            await task.socket.timeout(const Duration(seconds: 10));
            return task;
          } catch (error) {
            task.cancel();
            lastError = error;
          }
        } catch (error) {
          lastError = error;
        }
      }
      throw SocketException('No validated public address was reachable: $lastError');
    };
    try {
      final req = await client.getUrl(parsed);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.acceptHeader, 'text/plain, application/octet-stream, */*');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.isRedirect) throw const FormatException('Public source redirects are not allowed');
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final declaredLength = res.contentLength;
      if (declaredLength > maxBodyBytes) throw const FormatException('Source is larger than 2 MB');
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (received > maxBodyBytes) throw const FormatException('Source is larger than 2 MB');
        bytes.add(chunk);
      }
      final body = utf8.decode(bytes.takeBytes());
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
  static const maxBodyBytes = 2 * 1024 * 1024;\n  static const _textKey = 'sub_text', _timeKey = 'sub_time';

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
      final parsed = Uri.parse(url);
      final requestUri = parsed.replace(queryParameters: {...parsed.queryParameters, 't': '$bust'});
      final req = await client.getUrl(requestUri).timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      if (res.contentLength > maxBodyBytes) throw const FormatException('Subscription is larger than 2 MB');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > maxBodyBytes) {
          throw const FormatException('Subscription is larger than 2 MB');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    } finally {
      client.close(force: true);
    }
  }
}
