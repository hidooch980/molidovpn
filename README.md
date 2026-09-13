# VPN Config Aggregator v2

Collects free VLESS / VMess / Trojan / Shadowsocks / Hysteria2 / TUIC configs from public
sources, **really tests them through sing-box**, names each one by its **real exit location**,
sorts them and publishes subscription links — all inside GitHub Actions, free.

## How it works
1. Downloads every URL in `sources.txt` (plain text, base64 file or base64 lines).
2. Parses links into sing-box outbounds; broken/unsupported ones are dropped.
3. Dedupes by full connection settings (UUID, path, SNI...), not just `host:port`,
   so different configs behind the same CDN IP are kept.
4. Fast TCP pre-filter for TCP protocols (Hysteria2/TUIC are UDP and skip it).
5. Real test: each config runs in sing-box and an HTTPS request goes through it to
   Cloudflare's trace page. That gives the true latency **and** the exit country
   (even for CDN configs). GeoIP database is used only as a fallback.
6. Names like `🇩🇪 Germany 01 | vless | 142ms`, grouped by country (A→Z), fastest first inside each.

## Setup
```bash
gh auth login
bash setup.sh vpn-sub
```
The workflow runs every 30 minutes. Results go to the **`sub` branch**, force-pushed
without history, so the repo never grows.

## Links
Replace `USER/REPO`:

| File | Purpose |
|---|---|
| `https://raw.githubusercontent.com/USER/REPO/sub/sub_base64.txt` | main subscription (v2rayNG, Hiddify, NekoBox, Streisand) |
| `https://raw.githubusercontent.com/USER/REPO/sub/sub.txt` | same, plain text |
| `https://raw.githubusercontent.com/USER/REPO/sub/fastest.txt` | top 100 by latency |
| `https://raw.githubusercontent.com/USER/REPO/sub/country/DE.txt` | one country |
| `https://raw.githubusercontent.com/USER/REPO/sub/protocol/vless.txt` | one protocol |
| `https://raw.githubusercontent.com/USER/REPO/sub/singbox.json` | sing-box outbounds with `auto` url-test group |
| `https://github.com/USER/REPO/blob/sub/README.md` | status: countries, per-source quality |

## Testing from Iran
GitHub runners are outside Iran, so "alive" there does not guarantee it works from Iran.
Two fixes: use the url-test group in your client (Hiddify/NekoBox/sing-box `auto`), or register a
**self-hosted runner** on a Linux machine inside Iran and set the repository variable
`RUNNER` to its label — the same workflow then tests from there.

## Tuning (env vars)
`MAX_OUTPUT` (500), `MAX_REAL_TEST` (6000), `OUT_DIR` (output), `SINGBOX_BIN`, `GEOIP_DB`.

## Run locally
```bash
pip install -r requirements.txt
python -m unittest discover tests
python scanner.py   # uses sing-box from PATH or SINGBOX_BIN; falls back to TCP-only
```

## Security note
Free public configs are run by unknown people who can see your traffic metadata
and any unencrypted traffic. Only use HTTPS sites and avoid sensitive logins.
