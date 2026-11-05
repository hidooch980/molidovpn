import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/network/network_path_scorer.dart';

NetworkPathProbe probe(String id, {double latency = 40, double jitter = 5, double loss = 0, double throughput = 30, double reliability = 99, int failures = 0, double energy = 0.3}) =>
    NetworkPathProbe(id: id, kind: NetworkPathKind.wifi, latencyMs: latency, jitterMs: jitter, packetLossPercent: loss, throughputMbps: throughput, successRatePercent: reliability, consecutiveFailures: failures, energyCost: energy);

void main() {
  const scorer = NetworkPathScorer();
  test('prefers healthy low-latency path for interactive traffic', () {
    final ranked = scorer.rank([probe('slow', latency: 260, jitter: 70), probe('fast', latency: 28, jitter: 4)], useCase: NetworkUseCase.interactive);
    expect(ranked.first.probe.id, 'fast');
    expect(ranked.first.eligible, isTrue);
    expect(ranked.first.score, inInclusiveRange(0, 100));
  });
  test('streaming profile gives greater weight to throughput', () {
    final lowLatency = probe('low-latency', latency: 15, throughput: 15);
    final highCapacity = probe('high-capacity', latency: 75, throughput: 30);
    expect(scorer.rank([lowLatency, highCapacity]).first.probe.id, 'low-latency');
    expect(scorer.rank([lowLatency, highCapacity], useCase: NetworkUseCase.streaming).first.probe.id, 'high-capacity');
  });
  test('hard-failed path is ranked below eligible path', () {
    final ranked = scorer.rank([probe('dead', loss: 100, reliability: 0, failures: 10), probe('alive')]);
    expect(ranked.first.probe.id, 'alive');
    expect(ranked.last.eligible, isFalse);
  });
  test('ties are deterministic by id', () {
    final ranked = scorer.rank([probe('zeta'), probe('alpha')]);
    expect(ranked.map((item) => item.probe.id).toList(), ['alpha', 'zeta']);
  });
  test('rejects invalid measurements', () {
    expect(() => probe('bad', loss: 101), throwsArgumentError);
    expect(() => probe('bad', latency: double.nan), throwsArgumentError);
  });
}