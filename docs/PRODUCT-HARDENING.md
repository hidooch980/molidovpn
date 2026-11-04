# Molido Mesh AI — engineering hardening plan

Molido Mesh AI is the product name. MolidoVPN remains a legacy name in existing
package IDs, update feeds, repository paths, and older releases until a
compatibility-safe migration is proven.

## Product principles

1. **Fast path first:** tunnel establishment and packet forwarding must not wait
   for generative AI, analytics, remote control planes, or account services.
2. **Local-first intelligence:** deterministic measurements and on-device
   inference are preferred. Remote inference is optional and never required
   for a tunnel.
3. **Verified connectivity:** a probe score is only a ranking hint. Report
   Connected only after tunnel establishment and a health check through it.
4. **Safe failover:** use bounded retries, jittered backoff, and cooldowns to
   prevent battery drain and retry storms. Preserve a last-known-good path
   during candidate checks where the platform permits it.
5. **Privacy by design:** never collect packet payloads, messages, browsing
   history, credentials, or raw private addresses for AI or telemetry.
6. **Least privilege:** Gateway participation is opt-in, revocable, rate-limited,
   and isolated from the owner's LAN. Discovery never grants relay permission.
7. **Signed software:** verify signatures and hashes before accepting updates.
   AI cannot modify trust roots, DNS policy, or updater verification.

## Runtime architecture

- **Android VPN owner:** one Android VpnService owns the TUN interface and
  coordinates transports. Avoid competing independent VPN services.
- **Transport adapters:** sing-box, Xray, WireGuard-compatible transports, and
  supported fallback transports report explicit capabilities and health.
- **Path intelligence:** `lib/core/network/network_path_scorer.dart` ranks
  already-probed paths for balanced, interactive, streaming, and low-power use.
  It does not open sockets, change routes, or claim a path is connected.
- **AI router:** provider eligibility is explicit; unknown eligibility is
  denied. Provider errors fall back to deterministic policy. AI output is
  advisory and must pass ordinary validation.
- **Gateway registry:** publish only owner-approved, sanitized capability
  records. Keep secrets/private endpoints out of public catalogs. Require
  health checks, abuse controls, revocation, and replay-resistant signatures.
- **Update manager:** separate metadata verification, artifact hash checking,
  platform installation approval, health checks, and rollback policy.

## Connection decision pipeline

1. Detect available network transports and current VPN state.
2. Run a small, bounded probe set; avoid large downloads during discovery.
3. Reject invalid measurements and hard-failed candidates.
4. Rank remaining paths for the active use case.
5. Establish the selected tunnel through the platform VPN owner.
6. Verify DNS and reachability through the tunnel; check for leaks.
7. Only then publish Connected.
8. Monitor latency, jitter, loss, and tunnel health; fail over with cooldowns.
9. Cache only short-lived, non-sensitive quality summaries.

The path scorer is deliberately separate from the live tunnel controller until
integration tests prove route switching preserves TUN ownership and prevents
traffic leaks during transitions.

## AI provider availability

- On-device: preferred after model licence, ABI, memory, battery, and latency
  benchmarking.
- Self-hosted: enabled only for an operator-controlled and legally authorized
  deployment.
- Managed API: disabled unless the provider explicitly supports the operator,
  account, and deployment region.
- Offline policy: always available for measurable network decisions.

No location spoofing, identity falsification, credential sharing, or bypass of
provider restrictions is part of this product.

## Release gates

A release is not production-ready until all applicable checks pass:

- Flutter static analysis and unit tests.
- Android debug and release builds for supported ABIs.
- Native Rust core build and ABI packaging checks.
- Install/upgrade test over the previous signed Android package.
- VPN permission, connect/disconnect, process-death, reboot, and network
  handover tests on physical devices.
- DNS/IPv4/IPv6 leak tests and lockdown tests where supported.
- Gateway consent, revoke, isolation, quota, and abuse tests.
- Update signature/hash rejection and recovery tests.
- Battery and memory profiling on low- and mid-range devices.
- Persian, English, Arabic, and Turkish layout/RTL checks.

## Implementation status

This document is a target architecture and acceptance contract, not a claim
that every item is already implemented. The path scorer is an isolated,
unit-testable component. It must be integrated into the live connection
controller only after platform-specific failover and leak tests pass. The
existing Android application ID `com.mobin.mobin_vpn` is intentionally retained
to avoid breaking upgrades; only the visible product label is being migrated.
Build, physical-device, and leak-test results must be recorded before release.