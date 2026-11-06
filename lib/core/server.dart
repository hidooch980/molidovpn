import 'dart:convert';

import 'countries.dart';

enum Protocol { vless, vmess, trojan, shadowsocks, hysteria2, tuic, anytls, wireguard, socks, http, ikev2 }

class Server {
  Server({required this.uri, required this.remark, required this.countryCode, required this.protocol});

  final String uri;
  final String remark;
  final String countryCode;
  final Protocol protocol;

  static final _number = RegExp(r'(\d+)\s*·');

  String get countryLabel => countryName(countryCode);

  /// e.g. "آلمان 03"
  String get displayName {
    final n = _number.firstMatch(remark)?.group(1);
    return n == null ? countryLabel : '$countryLabel $n';
  }

  String get protocolLabel => switch (protocol) {
        Protocol.shadowsocks => 'SS',
        Protocol.hysteria2 => 'HY2',
        Protocol.anytls => 'AnyTLS',
        Protocol.wireguard => 'WireGuard',
        _ => protocol.name.toUpperCase(),
      };

  static Server? fromUri(String line) {
    final uri = line.trim();
    final protocol = switch (uri.split('://').first.toLowerCase()) {
      'vless' => Protocol.vless,
      'vmess' => Protocol.vmess,
      'trojan' => Protocol.trojan,
      'ss' => Protocol.shadowsocks,
      'hysteria2' || 'hy2' => Protocol.hysteria2,
      'tuic' => Protocol.tuic,
      'anytls' => Protocol.anytls,
      'wireguard' || 'wg' => Protocol.wireguard,
      'socks' || 'socks5' => Protocol.socks,
      'http' || 'https' => Protocol.http,
      'ikev2' => Protocol.ikev2,
      _ => null,
    };
    if (protocol == null) return null;
    final remark = _remark(uri, protocol);
    return Server(uri: uri, remark: remark, countryCode: countryCodeFromText(remark), protocol: protocol);
  }

  static String _remark(String uri, Protocol protocol) {
    try {
      if (protocol == Protocol.vmess) {
        final data = jsonDecode(decodeBase64Loose(uri.substring('vmess://'.length))) as Map;
        return '${data['ps'] ?? ''}';
      }
      final hash = uri.indexOf('#');
      return hash < 0 ? '' : Uri.decodeComponent(uri.substring(hash + 1));
    } catch (_) {
      return '';
    }
  }
}

String decodeBase64Loose(String text) {
  var t = text.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
  t = t.padRight(t.length + (4 - t.length % 4) % 4, '=');
  return utf8.decode(base64.decode(t));
}

/// Parses a subscription body (plain lines or one base64 blob) into servers.
List<Server> parseSubscription(String body) {
  var text = body.trim();
  if (!text.contains('://')) {
    try {
      text = decodeBase64Loose(text);
    } catch (_) {
      return const [];
    }
  }
  return [for (final line in const LineSplitter().convert(text)) ?Server.fromUri(line)];
}
