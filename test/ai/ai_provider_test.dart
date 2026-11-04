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

  @override
  bool get isAvailable => available;

  @override
  Future<String?> complete(AiRequest request) async {
    calls++;
    return output;
  }
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
  const request = AiRequest(task: 'route-health', input: {'loss': 0.0});

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
}
