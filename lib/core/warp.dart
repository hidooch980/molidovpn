import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// The registered WARP identity used by `warp://host:port` servers (set by the controller).
class WarpRegistry {
  static WarpAccount? account;
}

/// A definitive Cloudflare registration response. The caller uses the status to
/// avoid replaying device-creating requests after quota/server responses.
class WarpRegistrationRejected implements Exception {
  const WarpRegistrationRejected(this.statusCode, this.responseBody, this.retryAfter);

  final int statusCode;
  final String responseBody;
  final Duration? retryAfter;

  @override
  String toString() => 'WARP HTTP $statusCode: $responseBody';
}

/// A free Cloudflare WARP identity: used on its own as the free "WARP" route (no server needed),
/// or chained behind a VPN server so sites that block datacenter IPs see a Cloudflare IP instead.
class WarpAccount {
  /// Cloudflare WARP ingress addresses × ports; operators block some, so several are tried.
  static const endpoints = [
    '162.159.192.1:2408', '162.159.195.1:2408', '188.114.96.1:2408', '188.114.97.1:2408',
    '162.159.192.1:500', '162.159.192.1:1701', '162.159.192.1:4500', '162.159.195.1:854',
    '188.114.98.1:894', '188.114.99.1:7559', '162.159.192.10:8854', '162.159.193.1:2408',
  ];

  /// IPv6 WARP ingress (used only when the PC has global IPv6); brackets keep the port parseable.
  static const endpointsV6 = [
    '[2606:4700:d0::a29f:c001]:2408', '[2606:4700:d1::a29f:c001]:2408', '[2606:4700:d0::a29f:c001]:500',
  ];

  const WarpAccount({
    required this.privateKey,
    required this.peerPublicKey,
    required this.addressV4,
    required this.addressV6,
    required this.reserved,
  });

  static const endpointHost = 'engage.cloudflareclient.com';
  static const endpointPort = 2408;

  final String privateKey, peerPublicKey, addressV4, addressV6;
  final List<int> reserved;

  Map<String, dynamic> toJson() => {
        'privateKey': privateKey,
        'peerPublicKey': peerPublicKey,
        'v4': addressV4,
        'v6': addressV6,
        'reserved': reserved,
      };

  static WarpAccount? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return WarpAccount(
        privateKey: m['privateKey'] as String,
        peerPublicKey: m['peerPublicKey'] as String,
        addressV4: m['v4'] as String,
        addressV6: m['v6'] as String,
        reserved: (m['reserved'] as List).cast<int>(),
      );
    } catch (_) {
      return null;
    }
  }

  /// sing-box (Windows) WireGuard outbound that dials through [detour].
  Map<String, dynamic> singBoxOutbound(String tag, String detour) => {
        'type': 'wireguard',
        'tag': tag,
        'detour': detour,
        'server': endpointHost,
        'server_port': endpointPort,
        'local_address': ['$addressV4/32', '$addressV6/128'],
        'private_key': privateKey,
        'peer_public_key': peerPublicKey,
        'reserved': reserved,
        'mtu': 1280,
      };

  /// Xray (Android) WireGuard outbound that dials through the outbound tagged [dialerProxy].
  Map<String, dynamic> xrayOutbound(String tag, String dialerProxy) => {
        'tag': tag,
        'protocol': 'wireguard',
        'settings': {
          'secretKey': privateKey,
          'address': ['$addressV4/32', '$addressV6/128'],
          'peers': [
            {'publicKey': peerPublicKey, 'endpoint': '$endpointHost:$endpointPort', 'keepAlive': 30},
          ],
          'reserved': reserved,
          'mtu': 1280,
        },
        'streamSettings': {
          'sockopt': {'dialerProxy': dialerProxy},
        },
      };

  static const apiUrl = 'https://api.cloudflareclient.com/v0a2158/reg';

  /// MolidoVPN worker relay: same JSON body, forwarded to [apiUrl] with the right headers, response unchanged.
  static const relayUrl = 'https://molido-sub.hidooch980.workers.dev/warp/reg';

  /// Registers a new device with Cloudflare. [proxy] ("host:port") is used when the API is blocked locally;
  /// [url] may be [relayUrl] instead of the Cloudflare API.
  static Future<WarpAccount> register({String? proxy, String url = apiUrl}) async {
    final keyPair = await X25519().newKeyPair();
    final privateKey = base64.encode(await keyPair.extractPrivateKeyBytes());
    final publicKey = base64.encode((await keyPair.extractPublicKey()).bytes);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.userAgentHeader, 'okhttp/3.12.1')
        ..set('CF-Client-Version', 'a-6.10-2158');
      req.write(jsonEncode({
        'key': publicKey,
        'install_id': '',
        'fcm_token': '',
        'tos': DateTime.now().toUtc().toIso8601String(),
        'model': 'PC',
        'serial_number': '',
        'locale': 'en_US',
      }));
      final res = await req.close().timeout(const Duration(seconds: 12));
      final retryAfterRaw = res.headers.value('retry-after');
      final retryAfterSeconds = int.tryParse(retryAfterRaw ?? '');
      final retryAfter = retryAfterSeconds == null || retryAfterSeconds < 1
          ? null
          : Duration(seconds: retryAfterSeconds.clamp(1, 3600).toInt());
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        throw WarpRegistrationRejected(res.statusCode, body, retryAfter);
      }
      final result = (jsonDecode(body) as Map<String, dynamic>)['result'] as Map<String, dynamic>;
      final config = result['config'] as Map<String, dynamic>;
      final peer = (config['peers'] as List).first as Map<String, dynamic>;
      final addresses = (config['interface'] as Map<String, dynamic>)['addresses'] as Map<String, dynamic>;
      final clientId = config['client_id'] as String? ?? '';
      return WarpAccount(
        privateKey: privateKey,
        peerPublicKey: peer['public_key'] as String,
        addressV4: addresses['v4'] as String,
        addressV6: addresses['v6'] as String,
        reserved: clientId.isEmpty ? const [0, 0, 0] : base64.decode(clientId).take(3).toList(),
      );
    } finally {
      client.close(force: true);
    }
  }
}
