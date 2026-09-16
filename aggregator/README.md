# vpn-sub — MolidoVPN server aggregator

Collects free VLESS / VMess / Trojan / Shadowsocks / Hysteria2 / TUIC / AnyTLS configs from public
sources, **really tests them through sing-box**, names each one by its **real exit country**, and
publishes the tested lists that feed [MolidoVPN](https://github.com/hidooch980/molidovpn).

- **App & docs:** https://github.com/hidooch980/molidovpn
- **Website:** https://hidooch980.github.io/molidovpn/
- **Subscription worker (branded, Iran-ranked):** `https://molido-sub.hidooch980.workers.dev/sub/1` … `/sub/5`, `/ios`, `/hiddify`
- **Support:** Telegram [@Molido_Vpn](https://t.me/Molido_Vpn)

## How it works
1. Downloads every URL in `sources.txt` (plain text, base64 file or base64 lines).
2. **Every hour** the workflow also discovers new candidate sources via GitHub search (`discover.txt`).
3. Parses links into sing-box outbounds; broken/unsupported ones are dropped.
4. Dedupes by full connection settings (UUID, path, SNI…), not just `host:port`.
5. Fast TCP pre-filter, then a real HTTPS request through each config to Cloudflare's trace page:
   true latency **and** exit country.
6. Results are force-pushed (no history) to the **`sub` branch**.

The workflow (`.github/workflows/update.yml`) runs **every 15 minutes** and re-dispatches itself because
GitHub's cron is often delayed. Servers are additionally tested from inside Iran by the owner's PC; the
worker drops Iran-failed servers from its lists — see the
[architecture doc](https://github.com/hidooch980/molidovpn/blob/main/docs/ARCHITECTURE.md).

## Output files (`sub` branch)

| File | Purpose |
|---|---|
| `sub_base64.txt` / `sub.txt` | full tested list (base64 / plain) |
| `lite_base64.txt` | small list for iPhone clients |
| `fastest.txt` | top by latency |
| `country/DE.txt`, `protocol/vless.txt` | per country / protocol |
| `singbox.json` | sing-box outbounds with an `auto` url-test group |

Raw URL: `https://raw.githubusercontent.com/hidooch980/vpn-sub/sub/<file>`

## Run locally
```bash
pip install -r requirements.txt
python -m unittest discover tests
python scanner.py   # uses sing-box from PATH or SINGBOX_BIN
```

## Security note
Free public configs are run by unknown people who can see traffic metadata and any unencrypted
traffic. Prefer HTTPS sites and avoid sensitive logins.
