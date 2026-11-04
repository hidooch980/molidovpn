import 'dart:math' as math;

/// Traffic profile used to rank already-probed network paths.
enum NetworkUseCase { balanced, interactive, streaming, lowPower }
enum NetworkPathKind { wifi, cellular, ethernet, relay, unknown }

/// Sanitized measurements only. Never store payloads, credentials, browsing
/// history, or raw private addresses in this object.
class NetworkPathProbe {
  NetworkPathProbe({
    required this.id,
    required this.kind,
    required this.latencyMs,
    required this.jitterMs,
    required this.packetLossPercent,
    required this.throughputMbps,
    required this.successRatePercent,
    this.consecutiveFailures = 0,
    this.energyCost = 0.5,
  }) {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    _nonNegative(latencyMs, 'latencyMs');
    _nonNegative(jitterMs, 'jitterMs');
    _nonNegative(throughputMbps, 'throughputMbps');
    _percent(packetLossPercent, 'packetLossPercent');
    _percent(successRatePercent, 'successRatePercent');
    if (consecutiveFailures < 0) throw ArgumentError.value(consecutiveFailures, 'consecutiveFailures');
    if (!energyCost.isFinite || energyCost < 0 || energyCost > 1) {
      throw ArgumentError.value(energyCost, 'energyCost', 'Expected 0..1.');
    }
  }

  final String id;
  final NetworkPathKind kind;
  final double latencyMs;
  final double jitterMs;
  final double packetLossPercent;
  final double throughputMbps;
  final double successRatePercent;
  final int consecutiveFailures;
  final double energyCost;

  static void _nonNegative(double value, String name) {
    if (!value.isFinite || value < 0) throw ArgumentError.value(value, name, 'Expected finite value >= 0.');
  }
  static void _percent(double value, String name) {
    if (!value.isFinite || value < 0 || value > 100) throw ArgumentError.value(value, name, 'Expected 0..100.');
  }
}

class NetworkPathRank {
  const NetworkPathRank({required this.probe, required this.score, required this.eligible, required this.reasons});
  final NetworkPathProbe probe;
  final double score;
  final bool eligible;
  final List<String> reasons;
}

/// Ranks measured candidates. It does not open sockets or change system routes.
/// A score is a recommendation, never proof of connectivity.
class NetworkPathScorer {
  const NetworkPathScorer();

  List<NetworkPathRank> rank(Iterable<NetworkPathProbe> probes, {NetworkUseCase useCase = NetworkUseCase.balanced}) {
    final ranked = probes.map((probe) => _score(probe, useCase)).toList()
      ..sort((a, b) {
        if (a.eligible != b.eligible) return a.eligible ? -1 : 1;
        final scoreOrder = b.score.compareTo(a.score);
        if (scoreOrder != 0) return scoreOrder;
        final latencyOrder = a.probe.latencyMs.compareTo(b.probe.latencyMs);
        if (latencyOrder != 0) return latencyOrder;
        return a.probe.id.compareTo(b.probe.id);
      });
    return List.unmodifiable(ranked);
  }

  NetworkPathRank _score(NetworkPathProbe p, NetworkUseCase useCase) {
    final w = _weights(useCase);
    final latency = _decay(p.latencyMs, 450);
    final jitter = _decay(p.jitterMs, 100);
    final loss = _clamp(1 - p.packetLossPercent / 100) * _clamp(1 - p.packetLossPercent / 100) * 100;
    final throughput = _clamp(math.log(1 + p.throughputMbps) / math.log(101)) * 100;
    final reliability = _clamp(p.successRatePercent - math.min(p.consecutiveFailures * 7.0, 49.0));
    final energy = (1 - p.energyCost) * 100;
    final score = _clamp(latency * w.latency + jitter * w.jitter + loss * w.loss +
        throughput * w.throughput + reliability * w.reliability + energy * w.energy);
    final eligible = p.packetLossPercent < 100 && p.successRatePercent > 0 && p.consecutiveFailures < 10;
    final reasons = <String>[];
    if (!eligible) reasons.add('Path failed hard health gates.');
    if (p.packetLossPercent >= 5) reasons.add('Elevated packet loss.');
    if (p.jitterMs >= 40) reasons.add('Elevated jitter.');
    if (p.latencyMs >= 250) reasons.add('High latency.');
    if (p.consecutiveFailures > 0) reasons.add('Recent consecutive probe failures.');
    if (reasons.isEmpty) reasons.add('No measured quality warning.');
    return NetworkPathRank(probe: p, score: score, eligible: eligible, reasons: List.unmodifiable(reasons));
  }

  _Weights _weights(NetworkUseCase useCase) => switch (useCase) {
    NetworkUseCase.balanced => const _Weights(0.22, 0.16, 0.20, 0.10, 0.26, 0.06),
    NetworkUseCase.interactive => const _Weights(0.32, 0.24, 0.20, 0.04, 0.18, 0.02),
    NetworkUseCase.streaming => const _Weights(0.10, 0.10, 0.20, 0.32, 0.24, 0.04),
    NetworkUseCase.lowPower => const _Weights(0.14, 0.08, 0.16, 0.06, 0.26, 0.30),
  };
  double _decay(double value, double scale) => 100 * math.exp(-value / scale);
  double _clamp(double value) => value.clamp(0.0, 100.0).toDouble();
}

class _Weights {
  const _Weights(this.latency, this.jitter, this.loss, this.throughput, this.reliability, this.energy);
  final double latency, jitter, loss, throughput, reliability, energy;
}