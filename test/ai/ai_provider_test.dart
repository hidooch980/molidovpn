import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/ai/ai_provider.dart';

class FakeProvider implements AiProviderAdapter {
  FakeProvider({
    required this.id,
    required this.kind,
    required this.eligibility,
    this.output = 'ok',
    this.available = true,
  });

  @override
  final String id;
  @override
  final AiProviderKind kind;
  @override
  final AiProviderEligibility eligibility;
  final String? output;
  final bool available;
  int calls = 0;
  AiRequest? lastRequest;

  @override
  bool get isAvailable => available;

  @override
  Future<String?> complete(AiRequest request) async {
    calls++;
    lastRequest = request;
    return output;
  }

  test('provider receives only allowlisted network features', () async {
    final local = FakeProvider(
      id: 'local',
      kind: AiProviderKind.onDevice,
      eligibility: AiProviderEligibility.allowed,
    );
    final router = AiRouter(
      policy: const AiProviderPolicy(),
      offlinePolicy: FakeOfflinePolicy(),
      providers: [local],
    );
    const privateRequest = AiRequest(
      task: 'network-quality',
      input: {
        'latency_ms': 42,
        'network_type': 'WIFI',
        'ip_address': '203.0.113.7',
        'api_token': 'must-not-leak',
        'message': 'private text',
        'packet_loss_percent': 0.5,
      },
    );

    final result = await router.run(privateRequest);

    expect(result.usedOfflineFallback, isFalse);
    expect(local.lastRequest!.input, {
      'latency_ms': 42.0,
      'network_type': 'wifi',
      'packet_loss_percent': 0.5,
    });
  });

  test('unknown task or empty safe feature set never reaches provider', () async {
    final local = FakeProvider(
      id: 'local',
      kind: AiProviderKind.onDevice,
      eligibility: AiProviderEligibility.allowed,
    );
    final router = AiRouter(
      policy: const AiProviderPolicy(),
      offlinePolicy: FakeOfflinePolicy(),
      providers: [local],
    );

    final unknownTask = await router.run(
      const AiRequest(task: 'free-form-user-text', input: {'latency_ms': 20}),
    );
    final privateOnly = await router.run(
      const AiRequest(task: 'route-health', input: {'api_token': 'secret'}),
    );

    expect(unknownTask.usedOfflineFallback, isTrue);
    expect(privateOnly.usedOfflineFallback, isTrue);
    expect(local.calls, 0);
  });

}

class HangingProvider implements AiProviderAdapter {
  @override
  String get id => 'hanging-local';

  @override
  AiProviderKind get kind => AiProviderKind.onDevice;

  @override
  AiProviderEligibility get eligibility => AiProviderEligibility.allowed;

  @override
  bool get isAvailable => true;

  @override
  Future<String?> complete(AiRequest request) => Completer<String?>().future;
}

class FakeOfflinePolicy implements OfflineAiPolicy {
  @override
  String evaluate(AiRequest request) => 'offline-safe';
}

void main() {
  const request = AiRequest(task: 'route-health', input: {'packet_loss_percent': 0.0});

  test('unknown managed provider is never called', () async {
    final managed = FakeProvider(
      id: 'managed',
      kind: AiProviderKind.managed,
      eligibility: AiProviderEligibility.unknown,
    );
    final router = AiRouter(
      policy: const AiProviderPolicy(allowManaged: true),
      offlinePolicy: FakeOfflinePolicy(),
      providers: [managed],
    );

    final result = await router.run(request);

    expect(managed.calls, 0);
    expect(result.usedOfflineFallback, isTrue);
    expect(result.output, 'offline-safe');
  });

  test('on-device provider is preferred', () async {
    final managed = FakeProvider(
      id: 'managed',
      kind: AiProviderKind.managed,
      eligibility: AiProviderEligibility.allowed,
    );
    final local = FakeProvider(
      id: 'local',
      kind: AiProviderKind.onDevice,
      eligibility: AiProviderEligibility.allowed,
    );
    final router = AiRouter(
      policy: const AiProviderPolicy(allowManaged: true),
      offlinePolicy: FakeOfflinePolicy(),
      providers: [managed, local],
    );

    final result = await router.run(request);

    expect(result.providerId, 'local');
    expect(local.calls, 1);
    expect(managed.calls, 0);
  });

  test('provider failure falls back without throwing', () async {
    final unavailable = FakeProvider(
      id: 'local',
      kind: AiProviderKind.onDevice,
      eligibility: AiProviderEligibility.allowed,
      output: null,
    );
    final router = AiRouter(
      policy: const AiProviderPolicy(),
      offlinePolicy: FakeOfflinePolicy(),
      providers: [unavailable],
    );

    final result = await router.run(request);

    expect(result.usedOfflineFallback, isTrue);
    expect(result.output, 'offline-safe');
  });

  test('provider timeout uses one total budget and falls back', () async {
    final later = FakeProvider(
      id: 'self-hosted',
      kind: AiProviderKind.selfHosted,
      eligibility: AiProviderEligibility.allowed,
    );
    final router = AiRouter(
      policy: const AiProviderPolicy(allowSelfHosted: true),
      offlinePolicy: FakeOfflinePolicy(),
      providers: [HangingProvider(), later],
      providerBudget: const Duration(milliseconds: 20),
    );

    final result = await router.run(request);

    expect(result.usedOfflineFallback, isTrue);
    expect(result.output, 'offline-safe');
    expect(later.calls, 0);
  });

  test('oversized provider output is rejected', () async {
    final oversized = FakeProvider(
      id: 'local',
      kind: AiProviderKind.onDevice,
      eligibility: AiProviderEligibility.allowed,
      output: 'x' * 20,
    );
    final router = AiRouter(
      policy: const AiProviderPolicy(),
      offlinePolicy: FakeOfflinePolicy(),
      providers: [oversized],
      maxOutputChars: 10,
    );

    final result = await router.run(request);

    expect(result.usedOfflineFallback, isTrue);
    expect(result.output, 'offline-safe');
  });

  test('invalid provider budget and output cap are rejected', () {
    expect(
      () => AiRouter(
        policy: const AiProviderPolicy(),
        offlinePolicy: FakeOfflinePolicy(),
        providers: const [],
        providerBudget: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => AiRouter(
        policy: const AiProviderPolicy(),
        offlinePolicy: FakeOfflinePolicy(),
        providers: const [],
        maxOutputChars: 0,
      ),
      throwsArgumentError,
    );
  });
}
