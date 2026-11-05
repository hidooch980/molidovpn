# AI provider independence and regional availability

## Goal

Molido must remain usable when a hosted AI vendor is unavailable, unsupported in a user's region, rate-limited, or offline. AI is an optional advisory layer; the VPN data plane, DNS safety, kill switch, route validation, and recovery must continue without an AI provider.

## Compliance boundary

- Do not falsify location, identity, residency, billing details, or account information.
- Do not route API calls through a proxy or relay to evade a provider's sanctions, export controls, or regional eligibility rules.
- Use a managed provider only when that provider's current terms and applicable law permit the account, operator, and deployment.
- Treat eligibility as `unknown` until the operator has verified it. Unknown is not permission.
- Never embed provider API keys in the mobile app, repository, logs, or distributed configuration.
- For self-hosted inference, the operator must own/control the deployment and verify the model licence, hosting location, and applicable rules.

This is an engineering control, not legal advice. Provider terms and applicable restrictions change; review them before enabling a provider.

## Provider tiers

1. **On-device local model**: preferred when a suitable quantized model fits the device. Use an adapter around an approved on-device runtime (for example, ONNX Runtime Mobile or llama.cpp); ship no model until its licence, size, memory use, and Android ABI support are checked.
2. **Self-hosted model**: optional, configured by the operator on infrastructure they are authorized to use. Keep credentials server-side.
3. **Managed API**: disabled by default. Enable only after an explicit compliance/availability check for the provider and deployment. No location spoofing or sanctions circumvention.
4. **Deterministic offline policy engine**: always available. Handles measurable network decisions such as probe scoring, retry budgets, route health, cooldowns, and safe failover. It is not presented as a generative model.

## Failure behaviour

- Local policy engine is the final fallback.
- Provider timeouts, malformed output, quota errors, and network loss must not stop the VPN.
- All providers share a short total request budget (default 2 seconds); an individual timeout cannot consume an unbounded wait.
- Provider responses are capped (default 4,096 characters). Oversized or empty output is rejected.
- Only allowlisted, bounded network-quality features are forwarded (`latency_ms`, `jitter_ms`, `packet_loss_percent`, `throughput_mbps`, `success_rate_percent`, `consecutive_failures`, `energy_cost`, and fixed network/transport/use-case enums). Unknown keys, free text, IP addresses, identifiers, and credentials are dropped.
- AI output is advisory. It cannot directly install configs, trust a new gateway, change DNS/security policy, disable the kill switch, or publish software.
- Validate every proposed action against deterministic constraints and signed configuration policy.
- Do not send packet payloads, messages, browsing history, credentials, private IPs, or raw server secrets to an AI provider.
- Telemetry is opt-in, minimized, pseudonymous, and retention-limited.

## Rollout

1. Land the provider-neutral interface and tests.
2. Add deterministic network scoring and fallback.
3. Integrate an on-device inference runtime behind a feature flag after device benchmarks.
4. Add an operator-controlled self-hosted adapter.
5. Add managed adapters only after provider-specific eligibility review.
6. Run offline, airplane-mode, low-memory, timeout, malformed-output, and denied-provider tests.

## Acceptance criteria

- No provider key or private endpoint is present in the APK or Git history.
- A blocked/unknown provider is never called.
- VPN operation does not depend on any AI endpoint.
- A provider outage falls back without disconnecting an otherwise healthy tunnel.
- Unknown task types and requests with no allowlisted network features never reach a provider.
- A hung provider cannot consume more than the total AI request budget.
- AI cannot override security gates or signed update verification.
