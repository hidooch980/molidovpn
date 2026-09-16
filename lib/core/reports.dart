import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_log.dart';
import 'cf_clean_ip.dart';
import 'network_info.dart';

/// Opt-in anonymous server quality reports and the shared server scores.
/// Only a server fingerprint, success/failure, latency and network type are ever sent.
class ServerReports {
  static const _base = 'https://molido-sub.hidooch980.workers.dev';
  static const warpNode = 'mode:warp';

  static final Map<String, String> _fpCache = {};
  static String? _version;

  /// First 16 hex chars of SHA-256 over the server URI without its "#remark", trimmed.
  static Future<String> fingerprint(String uri) async {
    final cached = _fpCache[uri];
    if (cached != null) return cached;
    final hash = uri.indexOf('#');
    final clean = (hash < 0 ? uri : uri.substring(0, hash)).trim();
    final digest = await Sha256().hash(utf8.encode(clean));
    final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return _fpCache[uri] = hex.substring(0, 16);
  }

  static Future<String> _netType() async {
    final key = await NetworkInfo.networkKey();
    if (key == 'wifi') return 'wifi';
    if (key.startsWith('mobile')) return 'cellular';
    return 'other';
  }

  static Future<String> _appVersion() async {
    try {
      return _version ??= (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return 'unknown';
    }
  }

  /// Fire-and-forget; never throws. [node] is a fingerprint or [warpNode]; [mode] is the route (v2ray, warp,
  /// psiphon, tor, amnezia, dns) so the owner's stats can show the best mode per operator.
  static Future<void> send({required String node, required bool ok, int? ms, String? proxy, String? mode}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final body = jsonEncode({
        'v': 1,
        'node': node,
        'ok': ok,
        'ms': ms,
        'net': await _netType(),
        'app': Platform.isWindows ? 'windows' : Platform.operatingSystem,
        'ver': await _appVersion(),
        'op': ?NetworkInfo.operatorBucket,
        'mode': ?mode,
        'cfip': ?(ok ? CleanIp.takePendingShare() : null),
      });
      final req = await client.postUrl(Uri.parse('$_base/report')).timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>().timeout(const Duration(seconds: 10));
    } catch (e) {
      AppLog.add('report: not sent ($e)');
    } finally {
      client.close(force: true);
    }
  }

  static String? _sessionId;

  /// Random per-connection-session id, generated once and kept until [endSession]; only ever sent to
  /// /heartbeat (never any personal data), so the admin panel can count distinct connected sessions.
  static String _sessionIdFor() {
    final rnd = Random.secure();
    return _sessionId ??= List.generate(24, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  static void endSession() => _sessionId = null;

  /// Opt-in "still connected" ping; fire-and-forget, never throws. Call every ~45-60s while connected.
  static Future<void> heartbeat({String? proxy, String? mode}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final body = jsonEncode({
        'session_id': _sessionIdFor(),
        'op': ?NetworkInfo.operatorBucket,
        'mode': ?mode,
      });
      final req = await client.postUrl(Uri.parse('$_base/heartbeat')).timeout(const Duration(seconds: 8));
      req.headers.contentType = ContentType.json;
      req.write(body);
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>().timeout(const Duration(seconds: 8));
    } catch (_) {
      // Silent: offline / opted-out callers never reach here anyway.
    } finally {
      client.close(force: true);
    }
  }

  /// Reports needed before an operator's own score is trusted over the global one.
  static const minOperatorReports = 5;

  /// Fingerprint (or `mode:<route>`) -> score (0..1), or null when the endpoint is unreachable.
  /// [op]: ISP bucket (see [NetworkInfo.operatorBucket]) so scores reflect the user's operator; entries with
  /// fewer than [minOperatorReports] reports for that operator use the global score instead.
  static Future<Map<String, double>?> fetchScores({String? proxy, String? op}) async {
    final global = await _fetchScores(proxy, null);
    if (op == null) return global?.map((k, v) => MapEntry(k, v.$1));
    final mine = await _fetchScores(proxy, op);
    if (mine == null && global == null) return null;
    final out = <String, double>{for (final e in (global ?? const {}).entries) e.key: e.value.$1};
    for (final e in (mine ?? const {}).entries) {
      if (e.value.$2 >= minOperatorReports || !out.containsKey(e.key)) out[e.key] = e.value.$1;
    }
    return out;
  }

  /// Node -> (score, reports).
  static Future<Map<String, (double, int)>?> _fetchScores(String? proxy, String? op) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final url = op == null ? '$_base/scores' : '$_base/scores?op=${Uri.encodeQueryComponent(op)}';
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final json = jsonDecode(await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 10)));
      if (json is! Map) return null;
      final out = <String, (double, int)>{};
      for (final e in json.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final score = v['score'], ok = v['ok'], fail = v['fail'];
        final n = v['n'] is num ? (v['n'] as num).toInt() : (ok is num ? ok.toInt() : 0) + (fail is num ? fail.toInt() : 0);
        if (score is num) out['${e.key}'] = (score.toDouble(), n);
      }
      return out;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
