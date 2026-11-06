import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/countries.dart';
import 'package:mobin_vpn/core/server.dart';
import 'package:mobin_vpn/core/subscription.dart';
import 'package:mobin_vpn/core/singbox_outbound.dart';
import 'package:mobin_vpn/core/updater.dart';

void main() {
  test('update version comparison', () {
    expect(Updater.isNewer('1.0.12', '1.0.9'), isTrue);
    expect(Updater.isNewer('1.0.9', '1.0.12'), isFalse);
    expect(Updater.isNewer('1.0.5', '1.0.5+5'), isFalse);
    expect(Updater.isNewer('1.1.0', '1.0.99'), isTrue);
  });

  test('remark gives country, number and protocol', () {
    final s = Server.fromUri(
      'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=reality&sni=a.com&pbk=KEY&sid=ab'
      '#Mobin%20%E2%9C%A6%20%F0%9F%87%A9%F0%9F%87%AA%20Germany%2003%20%C2%B7%20VLESS',
    )!;
    expect(s.countryCode, 'DE');
    expect(s.displayName, 'آلمان 03');
    expect(s.protocolLabel, 'VLESS');
    expect(flagEmoji('DE'), '🇩🇪');
  });

  test('vless reality -> sing-box outbound', () {
    final o = parseOutbound(
      'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=reality&type=grpc&serviceName=g'
      '&sni=a.com&fp=qq&pbk=KEY&sid=ab&flow=xtls-rprx-vision#x',
    )!;
    expect(o['type'], 'vless');
    expect(o['server_port'], 443);
    expect(o['flow'], 'xtls-rprx-vision');
    expect(o['tls']['reality']['public_key'], 'KEY');
    expect(o['tls']['utls']['fingerprint'], 'qq');
    expect(o['transport'], {'type': 'grpc', 'service_name': 'g'});
  });

  test('ws early data, vmess, ss, hysteria2, tuic', () {
    final ws = parseOutbound('trojan://pass@h.com:443?type=ws&path=%2Fp%3Fed%3D2048&host=cdn.com#x')!;
    expect(ws['transport'], {
      'type': 'ws', 'path': '/p', 'max_early_data': 2048,
      'early_data_header_name': 'Sec-WebSocket-Protocol', 'headers': {'Host': 'cdn.com'},
    });
    final vmessJson = base64.encode(utf8.encode(jsonEncode(
        {'add': 'v.com', 'port': '8080', 'id': 'uuid', 'net': 'ws', 'path': '/w', 'tls': 'tls', 'ps': 'n'})));
    expect(parseOutbound('vmess://$vmessJson')!['transport']['path'], '/w');
    final ss = parseOutbound('ss://${base64.encode(utf8.encode('aes-256-gcm:pw'))}@s.com:8388#x')!;
    expect([ss['method'], ss['password'], ss['server_port']], ['aes-256-gcm', 'pw', 8388]);
    expect(parseOutbound('hy2://pw@h.com:443?sni=x.com&obfs=salamander&obfs-password=o')!['obfs']['password'], 'o');
    expect(parseOutbound('tuic://u:p@t.com:443?alpn=h3')!['uuid'], 'u');
    expect(parseOutbound('vless://@1.2.3.4:443'), isNull);
    expect(parseOutbound('trojan://p@h.com:443?type=kcp'), isNull);
  });

  test('anytls, wireguard, socks, http', () {
    final a = parseOutbound('anytls://pw@a.com:443?sni=s.com#a')!;
    expect([a['type'], a['password'], a['tls']['server_name']], ['anytls', 'pw', 's.com']);
    final w = parseOutbound('wireguard://cHJpdg%3D%3D@8.8.4.4:51820?publickey=cGVlcg%3D%3D&address=10.0.0.2,fd00::2&reserved=1,2,3')!;
    expect([w['private_key'], w['peer_public_key'], w['local_address'], w['reserved']],
        ['cHJpdg==', 'cGVlcg==', ['10.0.0.2/32', 'fd00::2/128'], [1, 2, 3]]);
    final s = parseOutbound('socks://${base64.encode(utf8.encode('u:p'))}@1.1.1.1:1080')!;
    expect([s['username'], s['password']], ['u', 'p']);
    final h = parseOutbound('https://u:p@proxy.com:8443')!;
    expect([h['type'], h['username'], h['tls']['enabled']], ['http', 'u', true]);
    expect(Server.fromUri('wg://k@h.com:1')!.protocol, Protocol.wireguard);
    expect(parseOutbound('wireguard://k@h.com:51820?address=10.0.0.2'), isNull);
  });

  test('public profile feeds reject unsafe URL forms before network access', () async {
    await expectLater(PublicProfileSources.fetch('file:///etc/passwd'), throwsA(isA<FormatException>()));
    await expectLater(PublicProfileSources.fetch('https://user:password@example.com/feed'), throwsA(isA<FormatException>()));
    await expectLater(PublicProfileSources.fetch('not-a-url'), throwsA(isA<FormatException>()));
  });

  test('real published subscription parses', () {
    final path = Platform.environment['SUB_FILE'];
    if (path == null || !File(path).existsSync()) return;
    final servers = parseSubscription(File(path).readAsStringSync());
    final outbounds = servers.where((s) => parseOutbound(s.uri) != null).length;
    final named = servers.where((s) => s.countryCode != unknownCountry).length;
    // ignore: avoid_print
    print('servers=${servers.length} singbox_ok=$outbounds with_country=$named');
    expect(servers, isNotEmpty);
    expect(outbounds / servers.length, greaterThan(0.95));
  });
}
