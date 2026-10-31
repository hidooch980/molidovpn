import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'network_info.dart';

/// This install's random ID, `MLD-XXXX-XXXX` (Crockford base32, 40 bits). Made on first launch, kept in the
/// app's data (SharedPreferences); nothing derived from the PC or the person.
class InstallId {
  static const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static final _re = RegExp(r'^MLD-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$');
  static const _key = 'install_id';
  static String? _id;

  static String generate([Random? random]) {
    final r = random ?? Random.secure();
    final c = List.generate(8, (_) => alphabet[r.nextInt(32)]).join();
    return 'MLD-${c.substring(0, 4)}-${c.substring(4)}';
  }

  static bool valid(String? id) => id != null && _re.hasMatch(id);

  /// Typed by a person: case, spaces, and Crockford's look-alikes (O→0, I/L→1).
  static String? normalize(String input) {
    var body = input.trim().toUpperCase().replaceAll(' ', '');
    if (body.startsWith('MLD')) body = body.substring(3);
    body = body.replaceAll('-', '').replaceAll('O', '0').replaceAll('I', '1').replaceAll('L', '1');
    if (body.length != 8) return null;
    final id = 'MLD-${body.substring(0, 4)}-${body.substring(4)}';
    return valid(id) ? id : null;
  }

  static String get current => _id ?? '';

  static Future<String> load() async {
    if (_id != null) return _id!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (!valid(id)) {
      id = generate();
      await prefs.setString(_key, id);
    }
    return _id = id!;
  }
}

/// Per-install diagnostics: a local ring buffer of connection events (no configs, keys or full IPs), sent to
/// the Worker's /diag only when a connect fails (reports opt-in) or the user sends a report; at most once an
/// hour, and unsent events wait for the next chance.
class Diagnostics {
  static const max = 80;
  static const _key = 'diag_events', _sentKey = 'diag_sent_at', _sentMsKey = 'diag_sent_ms';
  static const _endpoint = 'https://molido-sub.hidooch980.workers.dev/diag';

  static final _uri = RegExp(
    r'\b(vless|vmess|trojan|ss|ssr|hysteria2?|hy2|tuic|anytls|wireguard|socks5?|https?)://\S+',
    caseSensitive: false,
  );
  static final _uuid = RegExp(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');
  static final _keyish = RegExp(r'\b(key|pbk|password|pass|token|secret|sid|uuid|id)=([^&\s]+)', caseSensitive: false);
  static final _ipv4 = RegExp(r'\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b');
  static final _longB64 = RegExp(r'[A-Za-z0-9+/=_-]{32,}');

  static String scrub(String text) {
    var s = text
        .replaceAllMapped(_uri, (m) => '${m[1]}://…')
        .replaceAll(_uuid, '<uuid>')
        .replaceAllMapped(_keyish, (m) => '${m[1]}=…')
        .replaceAllMapped(_ipv4, (m) => '${m[1]}.${m[2]}.x.x')
        .replaceAll(_longB64, '<…>');
    if (s.length > 400) s = s.substring(0, 400);
    return s;
  }

  static List<String> append(List<String> lines, String line) {
    final out = [...lines, line];
    return out.length > max ? out.sublist(out.length - max) : out;
  }

  static Future<void> record(String kind, String? method, String msg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final line = jsonEncode({
        'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'kind': kind,
        'method': method,
        'net': NetworkInfo.operatorBucket,
        'msg': scrub(msg),
      });
      await prefs.setStringList(_key, append(prefs.getStringList(_key) ?? const [], line));
    } catch (_) {}
  }

  /// Returns false when throttled or offline. [proxy]: the app's own proxy when connected.
  static Future<bool> upload({bool userAsked = false, bool reportsOn = false, String? proxy}) async {
    if (!userAsked && !reportsOn) return false;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (prefs.getInt(_sentMsKey) ?? 0) < 3600 * 1000) return false;
    final sentAt = prefs.getInt(_sentKey) ?? 0;
    final pending = (prefs.getStringList(_key) ?? const [])
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .where((e) => (e['at'] as num? ?? 0) > sentAt)
        .toList();
    if (pending.isEmpty) return true;
    final events = pending.length > 60 ? pending.sublist(pending.length - 60) : pending;
    final body = jsonEncode({
      'install_id': await InstallId.load(),
      'platform': 'windows',
      'ver': (await PackageInfo.fromPlatform()).version,
      'model': 'PC',
      'os': Platform.operatingSystemVersion.length > 40
          ? Platform.operatingSystemVersion.substring(0, 40)
          : Platform.operatingSystemVersion,
      'op': NetworkInfo.operatorBucket,
      'events': events,
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final req = await client.postUrl(Uri.parse(_endpoint));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      if (res.statusCode == 204 || res.statusCode == 429) {
        await prefs.setInt(_sentMsKey, now);
        await prefs.setInt(_sentKey, events.map((e) => (e['at'] as num).toInt()).reduce(max2));
        return true;
      }
      return false;
    } catch (e) {
      AppLog.add('diag: upload failed ($e)');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static int max2(int a, int b) => a > b ? a : b;
}
