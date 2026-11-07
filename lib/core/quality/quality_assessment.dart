import 'dart:math' as math;

/// Measurement provenance is explicit so estimates and old samples never look live.
enum MeasurementProvenance { measured, estimated, unavailable, stale }

enum QualityGrade { excellent, good, fair, poor, unknown }

enum SecurityCheck { pass, fail, unknown }

enum SecurityVerdict { secure, blocked, unverified }

class QualityMetrics {
  const QualityMetrics({
    this.downloadMbps,
    this.uploadMbps,
    this.pingMs,
    this.jitterMs,
    this.packetLossPct,
    this.connectMs,
  });

  final double? downloadMbps;
  final double? uploadMbps;
  final double? pingMs;
  final double? jitterMs;
  final double? packetLossPct;
  final double? connectMs;
}

class SecurityEvidence {
  const SecurityEvidence({
    required this.trafficTraversesTunnel,
    required this.dnsLeak,
    required this.ipv4Leak,
    required this.ipv6Leak,
    required this.killSwitch,
    this.killSwitchRequired = true,
  });

  /// PASS only when the test request was positively bound to the active VPN route.
  final SecurityCheck trafficTraversesTunnel;
  final SecurityCheck dnsLeak;
  final SecurityCheck ipv4Leak;
  final SecurityCheck ipv6Leak;
  final SecurityCheck killSwitch;
  final bool killSwitchRequired;

  SecurityVerdict get verdict {
    final checks = <SecurityCheck>[
      trafficTraversesTunnel,
      dnsLeak,
      ipv4Leak,
      ipv6Leak,
      if (killSwitchRequired) killSwitch,
    ];
    if (checks.contains(SecurityCheck.fail)) return SecurityVerdict.blocked;
    if (checks.every((check) => check == SecurityCheck.pass)) return SecurityVerdict.secure;
    return SecurityVerdict.unverified;
  }
}

class QualitySnapshot {
  const QualitySnapshot({
    required this.measuredAt,
    required this.provenance,
    required this.viaTunnel,
    required this.tunnelVerified,
    required this.metrics,
    required this.security,
  });

  final DateTime measuredAt;
  final MeasurementProvenance provenance;
  final bool viaTunnel;
  final bool tunnelVerified;
  final QualityMetrics metrics;
  final SecurityEvidence security;
}

class QualityAssessment {
  const QualityAssessment._();

  /// Weights: throughput 25%, latency 20%, stability 35%, connection time 20%.
  /// Unavailable dimensions are omitted and the remaining weights are normalized.
  static const int maxSampleAgeSeconds = 120;
  static const double minUsefulScore = 35;

  static double? _valid(double? value, {double min = 0, double max = double.infinity}) {
    if (value == null || !value.isFinite || value < min || value > max) return null;
    return value;
  }

  static double _clamp(double value) => value.clamp(0.0, 1.0).toDouble();

  static double? _logSpeed(double? value) {
    final v = _valid(value, min: 0);
    if (v == null) return null;
    if (v == 0) return 0;
    // 1 Mbps is a low baseline; 100 Mbps saturates the score.
    return _clamp(math.log(1 + v) / math.log(101));
  }

  static double? _latency(double? value) {
    final v = _valid(value, min: 0);
    if (v == null) return null;
    return _clamp(1 - (v / 1000));
  }

  static double? _stability(QualityMetrics metrics) {
    final loss = _valid(metrics.packetLossPct, min: 0, max: 100);
    final jitter = _valid(metrics.jitterMs, min: 0);
    if (loss == null && jitter == null) return null;
    final lossScore = loss == null ? null : 1 - loss / 100;
    final jitterScore = jitter == null ? null : _clamp(1 - jitter / 500);
    if (lossScore != null && jitterScore != null) return (lossScore + jitterScore) / 2;
    return lossScore ?? jitterScore;
  }

  static double? _connect(double? value) {
    final v = _valid(value, min: 0);
    if (v == null) return null;
    return _clamp(1 - v / 30000);
  }

  static bool _metricsAreValid(QualityMetrics metrics) {
    bool validIfPresent(double? value, {double min = 0, double max = double.infinity}) =>
        value == null || (value.isFinite && value >= min && value <= max);

    return validIfPresent(metrics.downloadMbps) &&
        validIfPresent(metrics.uploadMbps) &&
        validIfPresent(metrics.pingMs, max: 120000) &&
        validIfPresent(metrics.jitterMs, max: 120000) &&
        validIfPresent(metrics.packetLossPct, max: 100) &&
        validIfPresent(metrics.connectMs, max: 120000);
  }

  static bool isFresh(QualitySnapshot sample, DateTime now) {
    if (sample.provenance != MeasurementProvenance.measured) return false;
    final age = now.difference(sample.measuredAt);
    return !age.isNegative && age <= const Duration(seconds: maxSampleAgeSeconds);
  }

  static double? score(QualitySnapshot sample, {required DateTime now}) {
    if (!isFresh(sample, now) ||
        !sample.viaTunnel ||
        !sample.tunnelVerified ||
        !_metricsAreValid(sample.metrics)) {
      return null;
    }
    final m = sample.metrics;
    final down = _logSpeed(m.downloadMbps);
    final up = _logSpeed(m.uploadMbps);
    final speed = down == null && up == null
        ? null
        : ((down ?? 0) + (up ?? 0)) / ((down == null ? 0 : 1) + (up == null ? 0 : 1));
    final latency = _latency(m.pingMs);
    final stability = _stability(m);
    final connect = _connect(m.connectMs);

    // A quality grade requires real throughput plus at least one independent path-quality signal.
    if (speed == null || (latency == null && stability == null)) return null;

    // Keep weights explicit and normalize over actually measured dimensions.
    final weighted = <(double, double?)>[
      (0.25, speed),
      (0.20, latency),
      (0.35, stability),
      (0.20, connect),
    ];
    final available = weighted.where((item) => item.$2 != null).toList();
    if (available.isEmpty) return null;
    final weight = available.fold<double>(0, (sum, item) => sum + item.$1);
    final total = available.fold<double>(0, (sum, item) => sum + item.$1 * item.$2!);
    return (100 * total / weight).clamp(0.0, 100.0).toDouble();
  }

  static QualityGrade grade(double? score) {
    if (score == null || !score.isFinite || score < 0 || score > 100) return QualityGrade.unknown;
    if (score >= 85) return QualityGrade.excellent;
    if (score >= 70) return QualityGrade.good;
    if (score >= 50) return QualityGrade.fair;
    return QualityGrade.poor;
  }

  /// A score is never allowed to override a failed or unverified security gate.
  static bool mayReportConnected(QualitySnapshot sample, {required DateTime now}) {
    return isFresh(sample, now) &&
        sample.viaTunnel &&
        sample.tunnelVerified &&
        sample.security.verdict == SecurityVerdict.secure;
  }

  /// Automatic ranking must not use routes whose security evidence is failed or incomplete.
  static bool mayUseForAutomaticSelection(QualitySnapshot sample, {required DateTime now}) {
    return score(sample, now: now) != null &&
        sample.security.verdict == SecurityVerdict.secure;
  }

  static bool shouldConsiderFailover(double? currentScore, {int consecutiveBadSamples = 0}) {
    if (currentScore == null || !currentScore.isFinite || currentScore < 0 || currentScore > 100) return false;
    return currentScore < minUsefulScore && consecutiveBadSamples >= 2;
  }
}
