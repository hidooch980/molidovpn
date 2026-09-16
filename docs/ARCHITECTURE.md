# MolidoVPN architecture

[Back to README](../README.md) · No secrets are stored in this document or in any repository.

## Repositories

| Repo | Local clone | Contents |
|---|---|---|
| [hidooch980/molidovpn](https://github.com/hidooch980/molidovpn) | `D:\molido\mobin-vpn` | Flutter app (`lib/`, Windows build), Cloudflare worker (`cloudflare/`), website (`site/`), account panel (`panel/`, `supabase/`), release + core-update workflows, `tools/` |
| [hidooch980/molidovpn-android](https://github.com/hidooch980/molidovpn-android) | `D:\molido\molidovpn-android` | Native Android app (Kotlin + Rust core, AGPL-3.0), `remote/` lists (policy, SHARD nodes, Smart Split, Reality SNI, donate) |
| [hidooch980/vpn-sub](https://github.com/hidooch980/vpn-sub) | `D:\molido\vpn-aggregator` | Python scanner; publishes tested lists to its `sub` branch |
| (local only) | `D:\molido\localtest` | Iran local tester (`iran_node_test.py`, `upload_results.py`, `run_*.cmd`) |

Release artifacts (Android APKs + Windows) are published from **mobin-vpn** only.

## Data flow

```
public sources ─► vpn-sub scanner (15 min, GitHub Actions) ─► sub branch (sub_base64 / lite_base64)
                                                                    │
molidovpn-android/remote/shard-nodes.txt (sync-lists, hourly) ──────┤
owner items (D1, /admin) ───────────────────────────────────────────┤
anonymous reports + owner Iran tests (D1) ── ranking / Iran filter ─┤
                                                                    ▼
                                    molido-sub worker ─► /, /sub/1..5, /ios, /hiddify
                                                     ─► apps (Android, Windows), Hiddify/Streisand
```

## Cloudflare worker `molido-sub` (`cloudflare/sub-worker.js`)

`wrangler.toml`: D1 binding `DB` (database `molido-reports`), daily cron `17 3 * * *`, secret `ADMIN_KEY` (set with `npx wrangler secret put ADMIN_KEY`; never committed). Deploy: `cd cloudflare && npx wrangler deploy`.

| Route | Purpose |
|---|---|
| `/` | Full tested list, branded, owner configs first |
| `/sub/1` … `/sub/5` | Five balanced lists (50–100 each): CDN (SHARD) nodes, then TLS/Reality/QUIC, then rest; report-ranked; Iran-failed dropped |
| `/lite`, `/ios` | iPhone-friendly list (≤ 80; no plain SS / non-TLS VMess) |
| `/hiddify` | `/ios` plus `warp://` WARP and WARP-in-WARP entries |
| `/report` | POST anonymous connection result (rate-limited 60/min; owner test uploads) |
| `/scores[?op=]` | 6-day success/latency scores per node fingerprint and `mode:<route>`, optionally per operator |
| `/owner/configs` | Owner configs due for the local Iran test |
| `/app/latest.json`, `/app/<asset>` | Latest GitHub release metadata / asset proxy (for filtered GitHub) |
| `/app/notice.json` | Active announcement (`{}` when none), cached 60 s |
| `/app/flags.json` | Remote flags `{v, default_mode, disabled[], notice}`, cached 60 s |
| `/remote/<file>` | `policy.json`, `shard-nodes.txt`, `smart-split.json` from molidovpn-android (GitHub → jsDelivr fallback) |
| `/warp/reg` | WARP registration proxy |
| `/admin` | Owner panel (HTML) |
| `/admin/api/items` (GET/POST), `/admin/api/items/:id` (PATCH/DELETE) | Owner configs and sub links; PATCH `enabled`, `always_show`, `retest` |
| `/admin/api/notice` (GET/PUT) | Announcement |
| `/admin/api/flags` (GET/PUT) | Remote mode flags (`warp, masque, gool, amnezia, psiphon, tor, dns, shard, v2ray`) |
| `/admin/api/stats` | 14-day stats per day / operator / mode |

Admin auth: `Authorization: Bearer <ADMIN_KEY>`, timing-safe compare, lockout after 5 fails for 15 min keyed by a salted IP hash (rows removed after a day).

Branding: every config is renamed `<flag> MolidoVPN NN`; owner configs get a ` VIP` suffix.

Owner Iran logic: a config is hidden after 2 consecutive failed local runs (failures < 5 min apart count as one run) unless `always_show`; configs are due for the quick test when new, older than 1 h, or `retest` was pressed.

### D1 tables (`cloudflare/schema.sql`)

| Table | Contents |
|---|---|
| `reports` | Daily aggregates `(day, node, app, net)` → ok/fail/latency sums. No IPs. Rows older than 30 days deleted by cron |
| `owner_items` | Owner `sub`/`config` entries: value, note, enabled, always_show, due_at |
| `owner_tests` | Latest local Iran result per config fingerprint, fail streak (30-day retention) |
| `owner_kv` | `notice` and `flags` JSON |
| `admin_fails` | Login lockout per salted IP hash (1-day retention) |

## Apps

- **Windows (Flutter, `lib/`)** — sing-box core (TUN or system proxy), bundled Xray-core for XHTTP, Psiphon, Tor, AmneziaWG. Routes: `auto`, `v2ray`, `warp`, `psiphon`, `tor`, `dns`, plus V2Ray-over-Psiphon and smart chains in automatic mode. Key files: `core/vpn_controller.dart` (selection, Iran-exit check, anti-freeze, background scanner), `core/remote_config.dart` (flags/notice), `core/reports.dart`, `core/updater.dart`.
- **Android (Kotlin, molidovpn-android)** — `VpnService` + TUN, Rust core (MASQUE, WireGuard/WARP, WARP-on-WARP), AmneziaWG, Psiphon, Tor, V2Ray/sing-box, SHARD, DNS-only. `AppRemote.kt` reads flags/notice; `ConnectionReports.kt` handles operator buckets and scores.

Both apps: opt-in anonymous reports, per-operator scores from `/scores?op=`, auto update via GitHub or `/app/latest.json`.

## Workflows

| Repo / workflow | Trigger | Does |
|---|---|---|
| mobin-vpn `release.yml` | push to `main` (not `**.md`), dispatch | Flutter analyze + tests → build Android APKs from molidovpn-android → **emulator connect test** (`tools/connect-test.sh`) → Windows build with pinned cores (SHA-256 verified) → GitHub Release `v2.0.<run>` |
| mobin-vpn `core-updates.yml` | every 6 h (`17 */6`) | `tools/check-core-updates.py` rewrites `tools/core-pins.json`, commits, dispatches release; dispatches release for new Android core commits; opens a "manual follow-up" issue for changes that need review; monthly empty commit keeps schedules alive |
| mobin-vpn `panel.yml` ("Website") | push to `site/`, `panel/` | Deploys GitHub Pages: install page at `/`, account panel at `/panel` |
| molidovpn-android `release.yml` | push to `main` | Builds APK artifacts |
| molidovpn-android `core-updates.yml` | every 6 h (`40 */6`) | Android core updates (`Core update (Android): …`) |
| molidovpn-android `sync-lists.yml` | hourly (self re-dispatching) | Syncs `remote/*` lists, appends tested SHARD-compatible servers |
| vpn-sub `update.yml` | every 15 min (self re-dispatching) + hourly discovery | Scan, test, publish to `sub` branch |

Documentation-only commits use `[skip ci]`.

## Core pins (`tools/core-pins.json`)

`SINGBOX_WINDOWS_MINOR` (1.12; new minors ignored, patches auto), `XRAY_VERSION` + SHA-256, `TOR_BROWSER_VERSION` + SHA-256, `PSIPHON_COMMIT` + SHA-256, `AWG_VERSION` + MSI SHA-256. A broken core never ships because release publishing is gated by tests and the emulator connection test.

## Local Iran tester (`D:\molido\localtest`)

Runs on the owner's Windows PC inside Iran via Task Scheduler, skipped when a system proxy is on:

- `run_iran_test.cmd` (every 2 h): tests all list servers with `sing-box`, `upload_results.py` sends anonymous results to `/report`.
- `run_owner_test.cmd` (every 15 min): `--owner-only`, tests owner configs that are due; uploads with `owner:true` into `owner_tests`.

If the PC is off, everything else keeps running; only Iran test results and owner badges go stale.
