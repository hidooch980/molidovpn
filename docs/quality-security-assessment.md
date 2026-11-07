# Smart Quality & Security Assessment

This document describes the first platform-neutral assessment layer. It is not a claim that every platform probe is implemented.

## Design invariants

1. Speed and security are separate dimensions. A fast route with a confirmed leak is still blocked.
2. A measurement must be fresh, measured (not estimated), and positively associated with the active tunnel path before it can receive a quality score.
3. Missing data is unknown, never silently converted to zero or a pass.
4. If any supplied metric is malformed (NaN, infinity, negative, or outside its accepted range), reject the complete sample.
5. Unknown security evidence cannot be promoted to secure.
6. Automatic candidate selection must require both a usable quality score and a fully passing security verdict.
7. A failed or unverified security state must never be bypassed by a high quality score.

## Metric model

The current heuristic weights are:

| Dimension | Weight |
|---|---:|
| Download/upload throughput | 25% |
| Median latency | 20% |
| Jitter and probe loss | 35% |
| Connection establishment time | 20% |

Only dimensions with valid measurements are included and their weights are normalized. A grade is withheld unless there is at least one real throughput measurement and at least one independent path-quality signal (latency or stability).

The speed curve uses a logarithmic scale and saturates at 100 Mbps. Latency and connection-time curves are bounded. These are initial engineering heuristics, not claims of calibrated user-perceived quality; they should be calibrated with a representative, privacy-safe dataset before using the score for automatic fleet-wide ranking.

## Freshness and validity

- Live samples expire after 120 seconds.
- Future timestamps are rejected.
- Only `measured` provenance is eligible for scoring.
- Download/upload must be finite and non-negative.
- Latency, jitter and connection time must be finite and within 0–120,000 ms.
- Packet loss must be finite and within 0–100%.

## Security verdict

Security checks are tri-state: `pass`, `fail`, `unknown`.

- Any applicable confirmed failure produces `blocked`.
- All applicable checks must pass to produce `secure`.
- Any missing/unknown evidence produces `unverified`.
- Kill Switch applicability is explicit and must reflect the user's actual platform policy.

Current evidence fields include tunnel-path attestation, DNS leak, IPv4 leak, IPv6 leak and Kill Switch behavior. The assessment class does not perform these probes itself; platform adapters must produce evidence from real tests.

## Current integration boundary

- Windows settings speed test explicitly sends its requests through the local proxy and brackets the transfer with the Windows engine's HTTPS health check. This is not a DNS/IPv4/IPv6 leak test and does not validate Kill Switch behavior.
- Android has a separate native speed-test implementation. It must not be confused with the Flutter Windows proxy test; native TUN results require a separate verified integration path.
- The assessment model is not yet the live connection-state gate or the server-ranking input.

## Release gate

Do not claim secure status from CI alone. Before release, run and retain real-device evidence for Android and real-network Windows evidence for:
- DNS resolver and DNS leak behavior;
- IPv4 and IPv6 routing/leak behavior (including explicitly unsupported families);
- Kill Switch during tunnel loss, core crash, reconnect and user disconnect;
- actual HTTPS payload transfer through the intended tunnel path;
- network handover, sleep/resume and recovery;
- system-proxy vs full-TUN scope on Windows.

CI, emulator tests, isolated Kotlin compilation and physical-device/network tests must be reported separately.
