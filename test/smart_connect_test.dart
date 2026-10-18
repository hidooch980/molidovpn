import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/server.dart';
import 'package:mobin_vpn/core/smart/smart_connect.dart';

Server srv(String uri, [Protocol p = Protocol.vless]) =>
    Server(uri: uri, remark: uri, countryCode: 'DE', protocol: p);

SmartCandidate cand(String uri, List<int> probes, {Protocol p = Protocol.vless, bool fragment = false}) =>
    SmartCandidate(srv(uri, p), fragment: fragment)..probes.addAll(probes);

void main() {
  group('score', () {
    test('no successful probe scores 0', () {
      expect(smartScore(const SmartMeasured(probes: [-1, -1])), 0);
      expect(smartScore(const SmartMeasured()), 0);
    });
    test('stable beats faster but flaky', () {
      final stable = smartScore(const SmartMeasured(probes: [300, 320, 310]));
      final flaky = smartScore(const SmartMeasured(probes: [120, -1, -1]));
      expect(stable, greaterThan(flaky));
    });
    test('faster wins at equal stability', () {
      expect(smartScore(const SmartMeasured(probes: [100, 100])),
          greaterThan(smartScore(const SmartMeasured(probes: [900, 900]))));
    });
    test('perfect route is 100 with full throughput prior', () {
      expect(smartScore(const SmartMeasured(probes: [80, 90, 100], throughput: 1)), closeTo(100, 0.01));
    });
    test('Iran exit halves the score', () {
      final a = smartScore(const SmartMeasured(probes: [200]));
      final b = smartScore(const SmartMeasured(probes: [200], exitIran: true));
      expect(b, closeTo(a / 2, 1e-9));
    });
    test('latency and connect normalisation bounds', () {
      expect(smartLatencyNorm(100), 1);
      expect(smartLatencyNorm(50), 1);
      expect(smartLatencyNorm(3000), closeTo(0, 1e-9));
      expect(smartLatencyNorm(10000), 0);
      expect(smartConnectNorm(1000), 1);
      expect(smartConnectNorm(90000), 0);
    });
    test('median and reason', () {
      expect(smartMedian([3, 1, 2]), 2);
      expect(smartMedian([1, 2, 3, 4]), 3);
      expect(smartMedian([]), isNull);
      expect(smartReason(const SmartMeasured(probes: [84, 90, -1]), stableWord: 'stable'), '87ms · 2/3 stable');
    });
  });

  group('config', () {
    test('defaults when missing or invalid', () {
      expect(SmartConfig.fromJson(null).enabled, isTrue);
      expect(SmartConfig.fromJson('x').concurrency, 12);
    });
    test('clamps values', () {
      final c = SmartConfig.fromJson({'enabled': false, 'concurrency': 999, 'probe_timeout_s': 0, 'stickiness': 80});
      expect(c.enabled, isFalse);
      expect(c.concurrency, 32);
      expect(c.probeTimeoutS, 2);
      expect(c.stickiness, 20);
    });
  });

  group('family', () {
    test('labels', () {
      expect(smartFamily(srv('vless://a@h:443?security=reality&type=tcp#x')), 'Reality');
      expect(smartFamily(srv('vless://a@h:443?security=tls&type=ws#x')), 'V2Ray CDN');
      expect(smartFamily(srv('vless://a@h:443?security=tls&type=xhttp#x')), 'XHTTP');
      expect(smartFamily(srv('hysteria2://a@h:443#x', Protocol.hysteria2)), 'Hysteria2');
      expect(smartFamily(srv('vless://a@h:443?security=tls&type=ws#x'), fragment: true), 'Fragment');
      expect(smartFamily(srv('psiphon://auto', Protocol.socks)), 'Psiphon');
      expect(smartFamily(srv('tor://auto', Protocol.socks)), 'Tor');
      expect(smartFamily(srv('warp://1.1.1.1:2408', Protocol.wireguard)), 'WARP');
    });
    test('expensive routes are not raced', () {
      expect(SmartCandidate(srv('tor://auto', Protocol.socks)).cost, SmartCost.expensive);
      expect(SmartCandidate(srv('viawarp:vless://x')).cost, SmartCost.expensive);
      expect(SmartCandidate(srv('vless://x')).cost, SmartCost.cheap);
    });
  });

  group('rank', () {
    test('responsive by score, then expensive, then failed', () {
      final slow = cand('vless://slow', [900, 950, 1000]);
      final fast = cand('vless://fast', [120, 130, 125]);
      final dead = cand('vless://dead', [-1]);
      final tor = SmartCandidate(srv('tor://auto', Protocol.socks));
      final order = smartRank([dead, tor, slow, fast]);
      expect(order.map((c) => c.server.uri), ['vless://fast', 'vless://slow', 'tor://auto', 'vless://dead']);
    });
    test('remembered winner gets stickiness, not more', () {
      final a = cand('vless://a', [200, 200, 200]);
      final b = cand('vless://b', [190, 190, 190]);
      final now = DateTime(2026);
      expect(smartRank([a, b]).first, b);
      expect(smartRank([a, b], memory: SmartMemoryEntry(winner: 'vless://a', at: now)).first, a);
      final far = cand('vless://c', [2500, 2600, 2700]);
      expect(smartRank([far, b], memory: SmartMemoryEntry(winner: 'vless://c', at: now)).first, b);
    });
    test('remembered expensive route goes first among expensive', () {
      final psi = SmartCandidate(srv('psiphon://auto', Protocol.socks));
      final tor = SmartCandidate(srv('tor://auto', Protocol.socks));
      final order = smartRank([psi, tor], memory: SmartMemoryEntry(winner: 'tor://auto', at: DateTime(2026)));
      expect(order.first, tor);
    });
    test('failed fragment variants are dropped', () {
      final f = cand('vless://x', [-1], fragment: true);
      expect(smartRank([f]), isEmpty);
    });
    test('fragment targets: failed TLS routes only', () {
      final ok = cand('vless://ok', [100]);
      final bad = cand('vless://bad', [-1]);
      final badReality = cand('vless://reality', [-1]);
      final t = smartFragmentTargets([ok, bad, badReality], (s) => !s.uri.contains('reality'), 5);
      expect(t.map((s) => s.uri), ['vless://bad']);
    });
  });

  group('memory', () {
    test('round trip, ttl and cap', () {
      final m = SmartMemory();
      final now = DateTime(2026, 10, 18);
      for (var i = 0; i < 20; i++) {
        m.remember('net$i', SmartMemoryEntry(winner: 'w$i', runnerUp: 'r$i', score: 80, at: now.add(Duration(minutes: i))));
      }
      expect(m.entries.length, SmartMemory.maxNetworks);
      expect(m.entries.containsKey('net0'), isFalse);
      final back = SmartMemory.decode(m.encode());
      expect(back.lookup('net19', now)?.runnerUp, 'r19');
      expect(back.lookup('net19', now.add(const Duration(days: 30)), ttlDays: 14), isNull);
      expect(SmartMemory.decode('garbage').entries, isEmpty);
    });
  });

  group('run state', () {
    test('chips, leader and progress', () {
      final run = SmartRun();
      final a = SmartCandidate(srv('vless://a?security=reality'));
      final b = SmartCandidate(srv('vless://b?security=reality'));
      final h = SmartCandidate(srv('hysteria2://h', Protocol.hysteria2));
      final tor = SmartCandidate(srv('tor://auto', Protocol.socks));
      for (final c in [a, b, h, tor]) {
        run.register(c);
      }
      run.total = 3;
      run.testing([a, b, h]);
      expect(run.families['Reality']!.status, SmartStatus.testing);
      run.record(a, -1);
      expect(run.families['Reality']!.status, SmartStatus.testing);
      run.record(b, 240);
      run.record(h, -1);
      expect(run.families['Reality']!.status, SmartStatus.ok);
      expect(run.families['Reality']!.bestMs, 240);
      expect(run.families['Hysteria2']!.status, SmartStatus.failed);
      expect(run.leader, b);
      expect(run.progress, 1);
      run.finish();
      expect(run.families['Tor']!.status, SmartStatus.skipped);
    });
  });
}
