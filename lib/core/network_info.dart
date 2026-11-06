import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'countries.dart';

/// The device's current network: connection type, carrier/ISP and public IP.
/// Before connecting this is the user's own internet; while connected the IP is the VPN exit.
class NetworkInfo extends ChangeNotifier {
  static const _channel = MethodChannel('mobin/native');

  String? type; // wifi | mobile | ethernet | none (Android only)
  String? carrier; // SIM operator name from Android
  String? ip, isp, countryCode;
  bool loading = false;
  bool _hasPendingRefresh = false;
  String? _pendingProxy;

  /// Drop the previous network address immediately when the tunnel state changes.
  void clearLookup() {
    ip = null;
    isp = null;
    countryCode = null;
    notifyListeners();
  }

  String get typeLabel => switch (type) {
        'wifi' => 'وای‌فای',
        'mobile' => 'دیتای موبایل',
        'ethernet' => 'اینترنت کابلی',
        'none' => 'بدون اینترنت',
        _ => 'اینترنت',
      };

  /// Persian name of well-known Iranian operators and ISPs, otherwise the raw name.
  String get providerLabel {
    final raw = '${isp ?? ''} ${type == 'mobile' ? carrier ?? '' : ''}'.toLowerCase();
    const known = {
      'mobile communication company of iran': 'همراه اول',
      'mci': 'همراه اول',
      'hamrah': 'همراه اول',
      'irancell': 'ایرانسل',
      'mtn': 'ایرانسل',
      'rightel': 'رایتل',
      'telecommunication company of iran': 'مخابرات',
      'tci': 'مخابرات',
      'shatel': 'شاتل',
      'asiatech': 'آسیاتک',
      'pars online': 'پارس‌آنلاین',
      'parsonline': 'پارس‌آنلاین',
      'mobinnet': 'مبین‌نت',
      'respina': 'رسپینا',
      'hiweb': 'های‌وب',
      'pishgaman': 'پیشگامان',
      'afranet': 'افرانت',
      'cloudflare': 'Cloudflare WARP',
    };
    for (final e in known.entries) {
      if (raw.contains(e.key)) return e.value;
    }
    return (isp?.isNotEmpty ?? false) ? isp! : (carrier ?? 'نامشخص');
  }

  String get countryLabel => countryCode == null ? '' : countryName(countryCode!);

  /// Stable id of the current underlying network for per-network memory: "wifi", "mobile:Irancell", "desktop".
  static Future<String> networkKey() async {
    if (!Platform.isAndroid) return 'desktop';
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('networkInfo');
      final type = m?['type'] as String? ?? 'unknown';
      final op = (m?['operator'] as String? ?? '').trim().toLowerCase();
      return type == 'mobile' && op.isNotEmpty ? 'mobile:$op' : type;
    } catch (_) {
      return 'unknown';
    }
  }

  static String? _ownProvider;

  /// Country of the user's own network (a lookup outside the VPN), e.g. "IR"; null until known.
  static String? ownCountry;

  /// Exit country as Cloudflare sees it, from /cdn-cgi/trace through [proxy] ("host:port"). null on failure.
  static Future<String?> traceCountry(String proxy, {Duration timeout = const Duration(seconds: 5)}) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'PROXY $proxy';
    try {
      Future<String> fetch() async {
        final res = await (await client.getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))).close();
        return res.transform(utf8.decoder).join();
      }

      final body = await fetch().timeout(timeout);
      for (final line in const LineSplitter().convert(body)) {
        if (line.startsWith('loc=')) return line.substring(4).trim().toUpperCase();
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Coarse ISP bucket of the user's own network for reports/scores: mci, irancell, tci, rightel, shatel or other.
  /// null until a lookup outside the VPN has run.
  static String? get operatorBucket {
    final raw = _ownProvider;
    if (raw == null || raw.trim().isEmpty) return null;
    if (raw.contains('cloudflare')) return null; // measured through WARP, not the user's ISP
    if (raw.contains('mobile communication company of iran') || raw.contains('hamrah') || raw.contains('mci')) return 'mci';
    if (raw.contains('irancell') || raw.contains('mtn')) return 'irancell';
    if (raw.contains('rightel')) return 'rightel';
    if (raw.contains('telecommunication company of iran') || raw.contains('tci')) return 'tci';
    if (raw.contains('shatel')) return 'shatel';
    return 'other';
  }

  /// True when the PC is online through a cellular modem or a USB-tethered phone (smaller MTU helps there).
  /// Heuristic on adapter names; Wi-Fi / Ethernet (the usual Windows case) returns false.
  static Future<bool> cellularLike() async {
    try {
      if (Platform.isAndroid) return (await networkKey()).startsWith('mobile');
      final interfaces = await NetworkInterface.list(includeLinkLocal: false, type: InternetAddressType.IPv4);
      const hints = ['cellular', 'mobile broadband', 'rndis', 'tether', 'wwan', 'android', 'iphone'];
      final names = [
        for (final i in interfaces)
          if (!i.name.toLowerCase().contains('mobinvpn') && i.addresses.any((a) => !a.isLoopback)) i.name.toLowerCase(),
      ];
      // Only when no ordinary Wi-Fi adapter is up as well.
      if (names.any((n) => n.contains('wi-fi') || n.contains('wlan') || n.contains('wireless'))) return false;
      return names.any((n) => hints.any(n.contains));
    } catch (_) {
      return false;
    }
  }

  /// Whether the PC had a global unicast IPv6 address (2000::/3) at the last [detectIpv6]; false until then.
  static bool globalIpv6 = false;

  /// Checks the adapters for a global IPv6 address (the VPN's own TUN adapter is ignored). Never throws.
  static Future<bool> detectIpv6() async {
    try {
      final interfaces = await NetworkInterface.list(includeLinkLocal: false, type: InternetAddressType.IPv6);
      globalIpv6 = interfaces.any((i) =>
          !i.name.toLowerCase().contains('mobinvpn') &&
          i.addresses.any((a) =>
              a.type == InternetAddressType.IPv6 && !a.isLoopback && (a.rawAddress[0] & 0xE0) == 0x20));
    } catch (_) {
      globalIpv6 = false;
    }
    return globalIpv6;
  }

  /// TUN MTU: [manual] when set (> 0), else 1340 on cellular / tethering and 1420 otherwise.
  static Future<int> tunMtu(int manual) async => manual > 0 ? manual : (await cellularLike() ? 1340 : 1420);

  Future<void> refresh({String? proxy}) async {
    if (loading) {
      // Do not lose a tunnel lookup if the initial device-IP request is still running.
      _pendingProxy = proxy;
      _hasPendingRefresh = true;
      return;
    }
    loading = true;
    notifyListeners();
    try {
      if (Platform.isAndroid) {
        final m = await _channel.invokeMapMethod<String, dynamic>('networkInfo');
        type = m?['type'] as String?;
        carrier = (m?['operator'] as String?)?.trim();
      }
      await _lookupIp(proxy);
      // Only a lookup outside the tunnel describes the user's own ISP.
      if (proxy == null && (isp != null || carrier != null)) {
        _ownProvider = '${isp ?? ''} ${type == 'mobile' ? carrier ?? '' : ''}'.toLowerCase();
      }
      if (proxy == null && countryCode != null && !(isp ?? '').toLowerCase().contains('cloudflare')) {
        ownCountry = countryCode!.toUpperCase();
      }
    } catch (e) {
      AppLog.add('network info: $e');
    } finally {
      loading = false;
      notifyListeners();
      if (_hasPendingRefresh) {
        final nextProxy = _pendingProxy;
        _pendingProxy = null;
        _hasPendingRefresh = false;
        unawaited(refresh(proxy: nextProxy));
      }
    }
  }

  Future<void> _lookupIp(String? proxy) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      for (final url in ['https://ipwho.is/', 'http://ip-api.com/json/?fields=query,isp,countryCode']) {
        try {
          final res = await (await client.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 10));
          final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
          ip = (j['ip'] ?? j['query']) as String?;
          isp = ((j['connection'] as Map?)?['isp'] ?? j['isp']) as String?;
          countryCode = (j['country_code'] ?? j['countryCode']) as String?;
          if (ip != null) return;
        } catch (_) {}
      }
    } finally {
      client.close(force: true);
    }
  }
}
