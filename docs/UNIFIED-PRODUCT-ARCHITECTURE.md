# MolidoVPN unified product plan

## Canonical repository

`hidooch980/molidovpn` is the canonical monorepo. Platform-specific clients remain isolated where their runtime and signing requirements differ, while version policy, release notes, shared server metadata, security policy and CI ownership live here.

| Area | Canonical path | Runtime |
|---|---|---|
| Windows desktop | `lib/`, `windows/` | Flutter + sing-box/Xray bridge |
| Android native client | `android-app/` | Kotlin + Rust + Android VPN APIs |
| Subscription Worker | `cloudflare/` | Cloudflare Workers |
| Website / iOS install guidance | `site/` | Static web/PWA |
| Server aggregation | `aggregator/` | Scheduled scanner |
| Shared docs and release policy | `docs/` | Platform-neutral |

The former Android repository remains a compatibility mirror while its workflows, signing secrets, release artifacts and update endpoints are migrated. Do not archive or delete it until a release has been built from this monorepo, installed on a physical Android device, and its in-app updater has been verified.

## Windows IKEv2 priority

IKEv2 is a first-class Windows roadmap item because the user reports good connection quality on Windows. The current Windows engine in `lib/core/windows_engine.dart` does not yet implement an IKEv2 profile provider; do not show IKEv2 as available in the Windows protocol picker until the native integration is complete.

Preferred implementation: use the Windows built-in VPN stack (IKEv2/IPsec) through a small, audited Windows platform adapter. Do not shell out with interpolated user strings. Use structured PowerShell/CIM or a native Ras/VPN API wrapper with strict argument handling.

Requirements:
- Provision and remove profiles idempotently; use stable, app-owned profile names.
- Validate hostnames, server identity, authentication mode and certificate chain before connecting.
- Never hard-code public credentials or store EAP passwords in logs, analytics, command-line arguments or plain-text config.
- Use Windows Credential Manager / OS-managed credential storage where supported.
- Support EAP-MSCHAPv2 and certificate authentication only when explicitly configured by a trusted provider.
- Verify tunnel state and actual traffic (IPv4, IPv6, DNS and route behavior); profile creation alone is not a successful connection.
- Implement connect timeout, cancellation, disconnect cleanup, network-change recovery and bounded retry.
- Add IKEv2 to automatic selection only after real Windows 10/11 tests; prefer measured success rate and latency per network rather than a fixed global ranking.
- Keep other transports as automatic fallback. Never force IKEv2 on networks where UDP 500/4500 or IPsec negotiation is blocked.

Security note: use modern AES-GCM/SHA-256 and strong DH/ECP groups supported by both server and client. Do not inherit legacy DES3/SHA1/DH2 defaults. Validate the server certificate identity and chain.

## Compact home screen

The default home should show only:
1. Connection state and one primary Connect/Disconnect action.
2. Current exit IP / country when available.
3. Selected location / server.
4. A concise server picker entry.
5. Settings and support entry points.

Hide route race panels, scan-method chips, DNS selectors, ping controls, network diagnostics and verbose protocol detail from the default home. Keep the actual automatic route discovery engine intact. Advanced diagnostics remain available from Servers / Settings, not on the first screen.

## IKEv2 directory maintenance

The Android IKEv2 directory refresh code, tests and validated last-known-good JSON are under `android-app/scripts/` and `android-app/data/ikev2/`. The unified workflow is `.github/workflows/refresh-ikev2-directory.yml`. It retries transient 429/5xx/network errors with bounded backoff and refuses to publish partial or invalid snapshots.

## Migration gates before retiring the Android mirror

- Run Android unit tests, Gradle build, emulator smoke test and physical-device install from this repository.
- Build Windows installer and portable ZIP from this repository; verify install, update, connect, disconnect and uninstall.
- Verify the same release tag/version and changelog across Android and Windows.
- Move all required signing and deployment secrets to the canonical repository.
- Verify Android and Windows update feeds and SHA-256 manifests.
- Only then freeze/archive the former Android repository and update external links.
