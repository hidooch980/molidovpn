/// Provider-neutral AI routing for Molido.
///
/// AI is advisory only. The VPN data plane and safety controls must never
/// depend on a hosted model being reachable.
enum AiProviderKind { onDevice, selfHosted, managed }

/// Unknown is deliberately not treated as permission.
enum AiProviderEligibility { allowed, denied, unknown }

class AiProviderPolicy {
  const AiProviderPolicy({
    this.allowOnDevice = true,
    this.allowSelfHosted = false,
    this.allowManaged = false,
  });

  final bool allowOnDevice;
  final bool allowSelfHosted;
  final bool allowManaged;

  bool permits(AiProviderKind kind, AiProviderEligibility eligibility) {
    if (eligibility != AiProviderEligibility.allowed) return false;
    return switch (kind) {
      AiProviderKind.onDevice => allowOnDevice,
      AiProviderKind.selfHosted => allowSelfHosted,
      AiProviderKind.managed => allowManaged,
    };
  }
}

class AiRequest {
  const AiRequest({
    required this.task,
    required this.input,
  });

  final String task;

  /// Must contain minimized, non-sensitive diagnostic features only.
  final Map<String, Object?> input;
}

abstract interface class AiProviderAdapter {
  String get id;
  AiProviderKind get kind;

  /// Must be verified by the deployment owner; never infer from IP geolocation.
  AiProviderEligibility get eligibility;

  bool get isAvailable;

  Future<String?> complete(AiRequest request);
}

class AiResult {
  const AiResult({
    required this.output,
    required this.providerId,
    required this.usedOfflineFallback,
  });

  final String output;
  final String providerId;
  final bool usedOfflineFallback;
}

/// Deterministic, network-safe fallback. This intentionally does not pretend
/// to be a generative model.
abstract interface class OfflineAiPolicy {
  String evaluate(AiRequest request);
}

class AiRouter {
  AiRouter({
    required this.policy,
    required this.offlinePolicy,
    required List<AiProviderAdapter> providers,
    this.providerBudget = const Duration(seconds: 2),
    this.maxOutputChars = 4096,
  }) : _providers = List.unmodifiable(providers) {
    if (providerBudget <= Duration.zero) {
      throw ArgumentError.value(providerBudget, 'providerBudget', 'Must be positive.');
    }
    if (maxOutputChars < 1) {
      throw ArgumentError.value(maxOutputChars, 'maxOutputChars', 'Must be positive.');
    }
  }

  final AiProviderPolicy policy;
  final OfflineAiPolicy offlinePolicy;
  final List<AiProviderAdapter> _providers;

  /// One total time budget for all providers, not a fresh timeout per provider.
  /// This keeps advisory AI from delaying network decisions indefinitely.
  final Duration providerBudget;

  /// Reject unexpectedly large provider responses before passing them onward.
  final int maxOutputChars;

  Future<AiResult> run(AiRequest request) async {
    final ordered = _providers.toList()
      ..sort((a, b) => _priority(a.kind).compareTo(_priority(b.kind)));
    final stopwatch = Stopwatch()..start();

    for (final provider in ordered) {
      final remaining = providerBudget - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      if (!policy.permits(provider.kind, provider.eligibility) ||
          !provider.isAvailable) {
        continue;
      }

      try {
        final output = await provider.complete(request).timeout(remaining);
        if (output != null &&
            output.trim().isNotEmpty &&
            output.length <= maxOutputChars) {
          return AiResult(
            output: output,
            providerId: provider.id,
            usedOfflineFallback: false,
          );
        }
      } catch (_) {
        // Timeout, malformed adapter behaviour, and provider errors are isolated.
        // The adapter should cancel its own underlying request when possible.
      }
    }

    return AiResult(
      output: offlinePolicy.evaluate(request),
      providerId: 'offline-policy',
      usedOfflineFallback: true,
    );
  }

  int _priority(AiProviderKind kind) => switch (kind) {
        AiProviderKind.onDevice => 0,
        AiProviderKind.selfHosted => 1,
        AiProviderKind.managed => 2,
      };
}
