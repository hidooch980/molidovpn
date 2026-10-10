import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/engine.dart';
import 'package:mobin_vpn/core/singbox_core.dart';
import 'package:mobin_vpn/core/singbox_outbound.dart';

const _uuid = '11111111-1111-1111-1111-111111111111';

void main() {
  const fragmentOn = EngineOptions(fragment: true);
  const fragmentOff = EngineOptions();

  group('TLS fragment', () {
    test('TLS over TCP gets record_fragment + fragment + fallback delay', () {
      final o = parseOutbound('trojan://pw@h.com:443?type=ws&path=%2Fw&sni=s.com#x')!;
      final tls = SingboxCore.tagged(o, 'proxy', fragmentOn)['tls'] as Map;
      expect(tls['record_fragment'], isTrue);
      expect(tls['fragment'], isTrue);
      expect(tls['fragment_fallback_delay'], SingboxCore.fragmentFallbackDelay);
      expect(tls['server_name'], 's.com');
    });

    test('off by default, never on Reality or QUIC (Hysteria2 / TUIC)', () {
      final trojan = parseOutbound('trojan://pw@h.com:443#x')!;
      expect((SingboxCore.tagged(trojan, 'p', fragmentOff)['tls'] as Map).containsKey('fragment'), isFalse);
      final reality = parseOutbound('vless://$_uuid@1.2.3.4:443?security=reality&sni=a.com&pbk=KEY&sid=ab#x')!;
      expect((SingboxCore.tagged(reality, 'p', fragmentOn)['tls'] as Map).containsKey('fragment'), isFalse);
      for (final link in ['hy2://pw@h.com:443?sni=x.com', 'tuic://u:p@t.com:443?alpn=h3']) {
        final tls = SingboxCore.tagged(parseOutbound(link)!, 'p', fragmentOn)['tls'] as Map;
        expect(tls.containsKey('fragment'), isFalse, reason: link);
        expect(tls.containsKey('record_fragment'), isFalse, reason: link);
      }
    });
  });

  group('multiplex', () {
    test('master switch is off by default (Xray servers do not speak sing-mux)', () {
      expect(SingboxCore.muxEnabled, isFalse);
      final o = parseOutbound('vless://$_uuid@1.2.3.4:443?security=tls&type=ws&sni=a.com#x')!;
      expect(SingboxCore.tagged(o, 'p', fragmentOff).containsKey('multiplex'), isFalse);
    });

    test('added for VLESS/VMess/Trojan over TCP/WS/gRPC when enabled', () {
      for (final link in [
        'vless://$_uuid@1.2.3.4:443?security=tls&sni=a.com#x',
        'vless://$_uuid@1.2.3.4:443?security=tls&type=ws&sni=a.com#x',
        'trojan://pw@h.com:443?type=grpc&serviceName=g#x',
      ]) {
        final m = SingboxCore.tagged(parseOutbound(link)!, 'p', fragmentOff, mux: true)['multiplex'] as Map?;
        expect(m, isNotNull, reason: link);
        expect(m!['enabled'], isTrue);
        expect(m['padding'], isTrue);
        expect(m['protocol'], 'h2mux');
        expect(m['max_connections'], lessThanOrEqualTo(4));
      }
    });

    test('never for Reality-Vision, Hysteria2, TUIC, XHTTP bridge or HTTP/2 transport', () {
      for (final link in [
        'vless://$_uuid@1.2.3.4:443?security=reality&sni=a.com&pbk=KEY&sid=ab&flow=xtls-rprx-vision#x',
        'hy2://pw@h.com:443?sni=x.com',
        'tuic://u:p@t.com:443?alpn=h3',
        'vless://$_uuid@1.2.3.4:443?security=tls&type=h2&sni=a.com#x',
      ]) {
        final o = SingboxCore.tagged(parseOutbound(link)!, 'p', fragmentOff, mux: true);
        expect(o.containsKey('multiplex'), isFalse, reason: link);
      }
      // XHTTP runs through the local Xray bridge, which reaches sing-box as a socks outbound.
      final bridge = {'type': 'socks', 'server': '127.0.0.1', 'server_port': 10808, 'version': '5'};
      expect(SingboxCore.muxCompatible(bridge), isFalse);
    });
  });

  group('Hysteria2 port hopping', () {
    test('mport range -> server_ports + hop_interval, no server_port', () {
      final o = parseOutbound('hysteria2://pw@h.com:443?sni=x.com&mport=20000-30000#x')!;
      expect(o['server_ports'], ['443:443', '20000:30000']);
      expect(o['hop_interval'], hy2HopInterval);
      expect(o.containsKey('server_port'), isFalse);
    });

    test('multi-port authority (official format)', () {
      final o = parseOutbound('hy2://pw@h.com:443,20000-30000/?sni=x.com#x')!;
      expect(o['server'], 'h.com');
      expect(o['server_ports'], ['443:443', '20000:30000']);
      final range = parseOutbound('hysteria2://pw@h.com:20000-30000?sni=x.com&hop_interval=60')!;
      expect(range['server_ports'], ['20000:30000']);
      expect(range['hop_interval'], '60s');
    });

    test('plain links keep server_port and get no invented range', () {
      final o = parseOutbound('hy2://pw@h.com:443?sni=x.com')!;
      expect(o['server_port'], 443);
      expect(o.containsKey('server_ports'), isFalse);
      expect(o.containsKey('hop_interval'), isFalse);
      expect(hy2PortRanges('30000-20000'), isNull);
      expect(hy2PortRanges('1-70000'), isNull);
      expect(parseOutbound('hy2://pw@h.com:443?mport=abc')!['server_port'], 443);
    });
  });

  test('multi-path urltest interval', () {
    expect(SingboxCore.multiPathInterval, '15s');
  });

  test('quick probe order: fastest good first, unknown kept, failed last', () {
    final order = quickProbeOrder(['a', 'b', 'c', 'd', 'e'], {'a': -1, 'b': 0, 'c': 300, 'd': 120});
    expect(order, ['d', 'c', 'b', 'e', 'a']);
    expect(quickProbeOrder(['a', 'b'], const {}), ['a', 'b']);
  });
}
