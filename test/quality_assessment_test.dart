import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/quality/quality_assessment.dart';

void main() {
  final now = DateTime.utc(2026, 11, 7, 12);
  SecurityEvidence secureEvidence() => const SecurityEvidence(
        trafficTraversesTunnel: SecurityCheck.pass,
        dnsLeak: SecurityCheck.pass,
        ipv4Leak: SecurityCheck.pass,
        ipv6Leak: SecurityCheck.pass,
        killSwitch: SecurityCheck.pass,
      );
  QualitySnapshot sample({
    DateTime? at,
    MeasurementProvenance provenance = MeasurementProvenance.measured,
    bool viaTunnel = true,
    bool tunnelVerified = true,
    SecurityEvidence? security,
    QualityMetrics metrics = const QualityMetrics(
      downloadMbps: 80,
      uploadMbps: 20,
      pingMs: 45,
      jitterMs: 8,
      packetLossPct: 0,
      connectMs: 1200,
    ),
  }) =>
      QualitySnapshot(
        measuredAt: at ?? now,
        provenance: provenance,
        viaTunnel: viaTunnel,
        tunnelVerified: tunnelVerified,
        metrics: metrics,
        security: security ?? secureEvidence(),
      );

  group('quality scoring', () {
    test('scores only fresh measured traffic verified through tunnel', () {
      expect(QualityAssessment.score(sample(), now: now), greaterThan(80));
      expect(QualityAssessment.score(sample(viaTunnel: false), now: now), isNull);
      expect(QualityAssessment.score(sample(tunnelVerified: false), now: now), isNull);
      expect(QualityAssessment.score(sample(provenance: MeasurementProvenance.estimated), now: now), isNull);
    });

    test('rejects stale, future and unavailable samples', () {
      expect(QualityAssessment.score(sample(at: now.subtract(const Duration(minutes: 3))), now: now), isNull);
      expect(QualityAssessment.score(sample(at: now.subtract(const Duration(seconds: 120))), now: now), isNotNull);
      expect(QualityAssessment.score(sample(at: now.subtract(const Duration(seconds: 121))), now: now), isNull);
      expect(QualityAssessment.score(sample(at: now.add(const Duration(seconds: 1))), now: now), isNull);
      expect(QualityAssessment.score(sample(provenance: MeasurementProvenance.unavailable), now: now), isNull);
    });

    test('normalizes available dimensions without inventing missing metrics', () {
      final onlyPing = sample(metrics: const QualityMetrics(pingMs: 100));
      expect(QualityAssessment.score(onlyPing, now: now), isNull);
      expect(QualityAssessment.score(sample(metrics: const QualityMetrics()), now: now), isNull);
    });

    test('rejects non-finite and out-of-range measurements', () {
      final bad = sample(metrics: const QualityMetrics(
        downloadMbps: double.nan,
        uploadMbps: double.infinity,
        pingMs: -5,
        jitterMs: double.nan,
        packetLossPct: 101,
        connectMs: -1,
      ));
      expect(QualityAssessment.score(bad, now: now), isNull);
      // A malformed optional field must invalidate the whole sample, not be silently ignored.
      final partlyBad = sample(metrics: const QualityMetrics(
        downloadMbps: 50,
        pingMs: 40,
        jitterMs: 12,
        packetLossPct: 101,
      ));
      expect(QualityAssessment.score(partlyBad, now: now), isNull);
    });

    test('grades boundaries', () {
      expect(QualityAssessment.grade(90), QualityGrade.excellent);
      expect(QualityAssessment.grade(75), QualityGrade.good);
      expect(QualityAssessment.grade(55), QualityGrade.fair);
      expect(QualityAssessment.grade(20), QualityGrade.poor);
      expect(QualityAssessment.grade(null), QualityGrade.unknown);
      expect(QualityAssessment.grade(-1), QualityGrade.unknown);
      expect(QualityAssessment.grade(101), QualityGrade.unknown);
    });
  });

  group('security gate', () {
    test('requires every security check to pass', () {
      expect(secureEvidence().verdict, SecurityVerdict.secure);
      const unknownDns = SecurityEvidence(
        trafficTraversesTunnel: SecurityCheck.pass,
        dnsLeak: SecurityCheck.unknown,
        ipv4Leak: SecurityCheck.pass,
        ipv6Leak: SecurityCheck.pass,
        killSwitch: SecurityCheck.pass,
      );
      expect(unknownDns.verdict, SecurityVerdict.unverified);
    });

    test('any leak or route failure blocks secure status', () {
      const leak = SecurityEvidence(
        trafficTraversesTunnel: SecurityCheck.pass,
        dnsLeak: SecurityCheck.fail,
        ipv4Leak: SecurityCheck.pass,
        ipv6Leak: SecurityCheck.pass,
        killSwitch: SecurityCheck.pass,
      );
      expect(leak.verdict, SecurityVerdict.blocked);
      // Speed quality and security are independent: a fast leaking route is still blocked.
      final fastButLeaking = sample(security: leak);
      expect(QualityAssessment.score(fastButLeaking, now: now), isNotNull);
      expect(QualityAssessment.mayReportConnected(fastButLeaking, now: now), isFalse);
      expect(QualityAssessment.mayUseForAutomaticSelection(fastButLeaking, now: now), isFalse);
    });

    test('does not report connected for unverified security', () {
      const unknown = SecurityEvidence(
        trafficTraversesTunnel: SecurityCheck.pass,
        dnsLeak: SecurityCheck.pass,
        ipv4Leak: SecurityCheck.unknown,
        ipv6Leak: SecurityCheck.pass,
        killSwitch: SecurityCheck.pass,
      );
      expect(QualityAssessment.mayReportConnected(sample(security: unknown), now: now), isFalse);
      expect(QualityAssessment.mayUseForAutomaticSelection(sample(security: unknown), now: now), isFalse);
    });

    test('kill switch can be explicitly not applicable', () {
      const noKillSwitchRequired = SecurityEvidence(
        trafficTraversesTunnel: SecurityCheck.pass,
        dnsLeak: SecurityCheck.pass,
        ipv4Leak: SecurityCheck.pass,
        ipv6Leak: SecurityCheck.pass,
        killSwitch: SecurityCheck.unknown,
        killSwitchRequired: false,
      );
      expect(noKillSwitchRequired.verdict, SecurityVerdict.secure);
    });
  });

  group('recovery policy', () {
    test('requires repeated poor samples and a real score', () {
      expect(QualityAssessment.shouldConsiderFailover(20, consecutiveBadSamples: 1), isFalse);
      expect(QualityAssessment.shouldConsiderFailover(20, consecutiveBadSamples: 2), isTrue);
      expect(QualityAssessment.shouldConsiderFailover(null, consecutiveBadSamples: 5), isFalse);
      expect(QualityAssessment.shouldConsiderFailover(50, consecutiveBadSamples: 5), isFalse);
      expect(QualityAssessment.shouldConsiderFailover(-1, consecutiveBadSamples: 5), isFalse);
      expect(QualityAssessment.shouldConsiderFailover(101, consecutiveBadSamples: 5), isFalse);
    });
  });
}
