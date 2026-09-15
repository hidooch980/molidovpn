#!/usr/bin/env python3
"""
VPN Config Aggregator v2
1. Fetch sources concurrently (plain / base64 / base64 lines)
2. Parse share links into sing-box outbounds; drop invalid/unsupported
3. Dedupe by full connection settings (not host:port)
4. Cheap TCP pre-filter (TCP protocols only; hysteria2/tuic skip it)
5. Real test through sing-box: HTTPS request via each proxy to Cloudflare trace
   -> measures real latency AND the real exit country (works for CDN configs too)
6. Rename every config "Mobin ✦ 🇩🇪 Germany 01 · VLESS", group by country, sort by latency
7. Write output/ (sub, base64, fastest, per-country, per-protocol, sing-box JSON, stats)
"""

import asyncio
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

import countries
from parsers import UDP_TYPES, dedupe_key, extract_configs, parse_uri, rename_uri

SOURCES_FILE = "sources.txt"
OUT_DIR = os.environ.get("OUT_DIR", "output")
SINGBOX = os.environ.get("SINGBOX_BIN") or shutil.which("sing-box")
SINGBOX_LATEST = os.environ.get("SINGBOX_LATEST_BIN")
GEOIP_DB = os.environ.get("GEOIP_DB", "GeoLite2-Country.mmdb")

FETCH_TIMEOUT = 20
TCP_TIMEOUT = 3.0
TCP_CONCURRENCY = 300
MAX_REAL_TEST = int(os.environ.get("MAX_REAL_TEST", "6000"))
BRAND = os.environ.get("BRAND", "Mobin")
MAX_PER_SERVER = 3
BATCH_SIZE = 200
BASE_PORT = 20000
PROXY_TIMEOUT = 8
TEST_WORKERS = 64
TEST_URL = "https://www.cloudflare.com/cdn-cgi/trace"
MAX_OUTPUT = int(os.environ.get("MAX_OUTPUT", "500"))
FASTEST_COUNT = 100
# Small list for iPhone/Hiddify: iOS VPN extensions have a tight memory limit.
LITE_COUNT = 40
LITE_PER_COUNTRY = 6
# Countries near Iran. Latency measured from GitHub's US/EU runners says nothing about latency from Iran,
# so these get reserved test slots, up to PREFERRED_KEEP guaranteed places each, and are listed first.
PREFERRED_COUNTRIES = [c.strip().upper() for c in
                       os.environ.get("PREFERRED_COUNTRIES", "TR,AE,AM,DE,NL").split(",") if c.strip()]
PREFERRED_KEEP = int(os.environ.get("PREFERRED_KEEP", "30"))
PREFERRED_TEST_MAX = int(os.environ.get("PREFERRED_TEST_MAX", "1500"))


@dataclass
class Node:
    uri: str
    outbound: dict
    source: str
    tcp_ms: float | None = None
    latency: float | None = None
    country: str = ""
    name: str = ""
    ip: str = ""
    hint: str = ""  # guessed country before the real test (remark flag / GeoIP of server IP)
    extra: dict = field(default_factory=dict)

    @property
    def proto(self) -> str:
        return self.outbound["type"].replace("shadowsocks", "ss")


# ---------------------------------------------------------------- fetch

def fetch(url: str) -> tuple[str, str]:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as resp:
            return url, resp.read().decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"  [skip] {url} -> {e}")
        return url, ""


def collect(sources: list[str], stats: dict) -> list[Node]:
    nodes, seen = [], set()
    with ThreadPoolExecutor(16) as pool:
        for url, blob in pool.map(fetch, sources):
            links = extract_configs(blob)
            parsed = unique = 0
            for uri in links:
                ob = parse_uri(uri)
                if ob is None:
                    continue
                parsed += 1
                key = dedupe_key(ob)
                if key in seen:
                    continue
                seen.add(key)
                unique += 1
                nodes.append(Node(uri, ob, url))
            stats["sources"][url] = {"links": len(links), "parsed": parsed, "new_unique": unique, "alive": 0}
            print(f"  {url} -> links={len(links)} parsed={parsed} new={unique}")
    return nodes


# ---------------------------------------------------------------- tcp pre-filter

async def _tcp(node: Node, sem: asyncio.Semaphore):
    async with sem:
        start = time.monotonic()
        try:
            _, w = await asyncio.wait_for(
                asyncio.open_connection(node.outbound["server"], node.outbound["server_port"]), TCP_TIMEOUT)
            node.tcp_ms = (time.monotonic() - start) * 1000
            node.ip = (w.get_extra_info("peername") or ("",))[0]
            w.close()
        except Exception:
            node.tcp_ms = None


async def tcp_filter(nodes: list[Node]) -> list[Node]:
    sem = asyncio.Semaphore(TCP_CONCURRENCY)
    tcp_nodes = [n for n in nodes if n.outbound["type"] not in UDP_TYPES]
    await asyncio.gather(*(_tcp(n, sem) for n in tcp_nodes))
    alive = sorted((n for n in tcp_nodes if n.tcp_ms is not None), key=lambda n: n.tcp_ms)
    udp = [n for n in nodes if n.outbound["type"] in UDP_TYPES]
    return alive + udp


def diversify(nodes: list[Node]) -> list[Node]:
    """Cap configs per server and round-robin across sources, so thousands of configs
    pointing at the same CDN IPs (fast TCP, mostly dead) don't crowd out real servers."""
    per_server, by_source = Counter(), defaultdict(list)
    for n in nodes:
        server = n.outbound["server"]
        if per_server[server] < MAX_PER_SERVER:
            per_server[server] += 1
            by_source[n.source].append(n)
    queues, result = list(by_source.values()), []
    for i in range(max((len(q) for q in queues), default=0)):
        result.extend(q[i] for q in queues if i < len(q))
    return result


_FLAG = re.compile("([\U0001F1E6-\U0001F1FF])([\U0001F1E6-\U0001F1FF])")
_NAME_HINTS = {"TR": r"turkey|t[üu]rkiye", "AE": r"\bUAE\b|emirates|dubai", "AM": r"armenia",
               "DE": r"germany", "NL": r"netherlands"}


def hint_countries(nodes: list[Node]):
    """Guess each node's country before testing: remark flag/name first, else GeoIP of the server IP."""
    from urllib.parse import unquote
    db = None
    if os.path.exists(GEOIP_DB):
        try:
            import maxminddb
            db = maxminddb.open_database(GEOIP_DB)
        except Exception:
            db = None
    for n in nodes:
        remark = unquote(n.uri.split("#", 1)[1]) if "#" in n.uri else ""
        m = _FLAG.search(remark)
        if m:
            n.hint = "".join(chr(ord(ch) - 0x1F1E6 + ord("A")) for ch in m.groups())
            continue
        n.hint = next((c for c, rx in _NAME_HINTS.items() if re.search(rx, remark, re.I)), "")
        if n.hint or not db:
            continue
        ip = n.ip or n.outbound["server"]
        try:
            rec = db.get(ip)
            n.hint = ((rec or {}).get("country") or {}).get("iso_code", "")
        except Exception:
            pass
    if db:
        db.close()


def log_countries(label: str, codes):
    c = Counter(code or "??" for code in codes)
    pref = " ".join(f"{p}={c.get(p, 0)}" for p in PREFERRED_COUNTRIES)
    top = " ".join(f"{k}={v}" for k, v in c.most_common(15))
    print(f"  [countries] {label}: preferred[{pref}] | top: {top}")


def pick_candidates(nodes: list[Node]) -> list[Node]:
    """Reserve test slots for preferred-country nodes; TCP ping from a US runner would sort them last."""
    pref = diversify([n for n in nodes if n.hint in PREFERRED_COUNTRIES])
    # Round-robin across preferred countries so NL/DE (plentiful) don't crowd out TR/AE/AM.
    by_c = defaultdict(list)
    for n in pref:
        by_c[n.hint].append(n)
    queues, reserved = [by_c[c] for c in PREFERRED_COUNTRIES], []
    for i in range(max((len(q) for q in queues), default=0)):
        reserved.extend(q[i] for q in queues if i < len(q))
    reserved = reserved[:PREFERRED_TEST_MAX]
    taken = {id(n) for n in reserved}
    rest = diversify([n for n in nodes if id(n) not in taken])
    return reserved + rest[:max(0, MAX_REAL_TEST - len(reserved))]


# ---------------------------------------------------------------- real test via sing-box

def _config(batch: list[Node]) -> dict:
    inbounds, outbounds, rules = [], [], []
    for i, n in enumerate(batch):
        inbounds.append({"type": "mixed", "tag": f"in{i}", "listen": "127.0.0.1", "listen_port": BASE_PORT + i})
        outbounds.append({**n.outbound, "tag": f"n{i}"})
        rules.append({"inbound": [f"in{i}"], "outbound": f"n{i}"})
    return {"log": {"level": "panic"}, "inbounds": inbounds, "outbounds": outbounds, "route": {"rules": rules}}


def _check(batch: list[Node], path: str, binary: str | None = None) -> tuple[bool, str]:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(_config(batch), f)
    r = subprocess.run([binary or SINGBOX, "check", "-c", path], capture_output=True, text=True)
    return r.returncode == 0, r.stdout + r.stderr


def _valid_subset(batch: list[Node], path: str, binary: str | None = None) -> list[Node]:
    """Drop nodes that make sing-box reject the config (it validates the whole file)."""
    while batch:
        ok, err = _check(batch, path, binary)
        if ok:
            return batch
        m = re.search(r"outbounds\[(\d+)\]", err)
        if m and int(m.group(1)) < len(batch):
            batch = batch[:int(m.group(1))] + batch[int(m.group(1)) + 1:]
            continue
        if len(batch) == 1:
            return []
        mid = len(batch) // 2
        return _valid_subset(batch[:mid], path, binary) + _valid_subset(batch[mid:], path, binary)
    return batch


def compat_filter(nodes: list[Node]) -> list[Node]:
    """Clients like Hiddify run a newer sing-box; one config it rejects stops their whole core."""
    if not SINGBOX_LATEST or not nodes:
        return nodes
    tmp = os.path.join(tempfile.gettempdir(), "vpnagg-compat.json")
    kept = []
    for b in range(0, len(nodes), BATCH_SIZE):
        kept.extend(_valid_subset(nodes[b:b + BATCH_SIZE], tmp, SINGBOX_LATEST))
    print(f"  compatible with latest sing-box: {len(kept)}/{len(nodes)}")
    return kept


def _probe(args):
    node, port = args
    proxy = f"http://127.0.0.1:{port}"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    start = time.monotonic()
    try:
        with opener.open(TEST_URL, timeout=PROXY_TIMEOUT) as resp:
            body = resp.read(2048).decode("utf-8", errors="ignore")
        node.latency = (time.monotonic() - start) * 1000
        m = re.search(r"^loc=([A-Z]{2})$", body, re.M)
        node.country = m.group(1) if m and m.group(1) != "XX" else ""
    except Exception:
        node.latency = None


def _wait_ports(ports: list[int], deadline: float):
    for p in ports:
        while time.monotonic() < deadline:
            try:
                socket.create_connection(("127.0.0.1", p), 0.3).close()
                break
            except OSError:
                time.sleep(0.2)


def real_test(nodes: list[Node]) -> list[Node]:
    tmp = os.path.join(tempfile.gettempdir(), "vpnagg-singbox.json")
    alive = []
    for b in range(0, len(nodes), BATCH_SIZE):
        batch = _valid_subset(nodes[b:b + BATCH_SIZE], tmp)
        if not batch:
            continue
        _check(batch, tmp)
        proc = subprocess.Popen([SINGBOX, "run", "-c", tmp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            _wait_ports([BASE_PORT, BASE_PORT + len(batch) - 1], time.monotonic() + 15)
            with ThreadPoolExecutor(TEST_WORKERS) as pool:
                list(pool.map(_probe, [(n, BASE_PORT + i) for i, n in enumerate(batch)]))
        finally:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        ok = [n for n in batch if n.latency is not None]
        alive.extend(ok)
        print(f"  batch {b // BATCH_SIZE + 1}: valid={len(batch)} alive={len(ok)}")
    return alive


# ---------------------------------------------------------------- geo fallback

def geo_fallback(nodes: list[Node]):
    missing = [n for n in nodes if not n.country]
    if not missing or not os.path.exists(GEOIP_DB):
        return
    try:
        import maxminddb
    except ImportError:
        return

    def resolve(n):
        try:
            return n, socket.getaddrinfo(n.outbound["server"], None)[0][4][0]
        except Exception:
            return n, None

    with maxminddb.open_database(GEOIP_DB) as db, ThreadPoolExecutor(64) as pool:
        for n, ip in pool.map(resolve, missing):
            rec = db.get(ip) if ip else None
            n.country = ((rec or {}).get("country") or {}).get("iso_code", "") if rec else ""


# ---------------------------------------------------------------- output

def write_lines(path: str, lines: list[str]):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))


def publish(nodes: list[Node], stats: dict, mode: str):
    by_latency = sorted(nodes, key=lambda n: n.latency)
    # Guaranteed places for preferred countries, then fill the global cap with the fastest of the rest.
    kept, per_pref = [], Counter()
    for n in by_latency:
        if n.country in PREFERRED_COUNTRIES and per_pref[n.country] < PREFERRED_KEEP:
            per_pref[n.country] += 1
            kept.append(n)
    kept_ids = {id(n) for n in kept}
    fill = [n for n in by_latency if id(n) not in kept_ids][:max(0, MAX_OUTPUT - len(kept))]
    fastest_first = sorted(kept + fill, key=lambda n: n.latency)
    by_country = defaultdict(list)
    for n in fastest_first:
        by_country[n.country].append(n)
    rank = {c: i for i, c in enumerate(PREFERRED_COUNTRIES)}
    order = sorted(by_country, key=lambda c: (rank.get(c, len(rank)), c == "", countries.name(c)))
    log_countries("published", (n.country for n in fastest_first))

    ordered = []
    for code in order:
        for i, n in enumerate(sorted(by_country[code], key=lambda n: n.latency), 1):
            n.name = f"{BRAND} ✦ {countries.flag(code)} {countries.name(code)} {i:02d} · {n.proto.upper()}"
            ordered.append(n)

    if os.path.isdir(OUT_DIR):
        shutil.rmtree(OUT_DIR)
    renamed = lambda ns: [rename_uri(n.uri, n.name) for n in ns]
    import base64
    write_lines(f"{OUT_DIR}/sub.txt", renamed(ordered))
    write_lines(f"{OUT_DIR}/sub_base64.txt", [base64.b64encode("\n".join(renamed(ordered)).encode()).decode()])
    write_lines(f"{OUT_DIR}/fastest.txt", renamed(sorted(ordered, key=lambda n: n.latency)[:FASTEST_COUNT]))

    lite, per_country = [], Counter()
    for n in sorted(ordered, key=lambda n: (n.country not in PREFERRED_COUNTRIES, n.latency)):
        if len(lite) < LITE_COUNT and per_country[n.country] < LITE_PER_COUNTRY:
            per_country[n.country] += 1
            lite.append(n)
    lite.sort(key=ordered.index)
    write_lines(f"{OUT_DIR}/lite.txt", renamed(lite))
    write_lines(f"{OUT_DIR}/lite_base64.txt", [base64.b64encode("\n".join(renamed(lite)).encode()).decode()])
    for code in order:
        write_lines(f"{OUT_DIR}/country/{code or 'XX'}.txt", renamed(by_country[code]))
    for proto in sorted({n.proto for n in ordered}):
        write_lines(f"{OUT_DIR}/protocol/{proto}.txt", renamed([n for n in ordered if n.proto == proto]))

    tags = [n.name for n in ordered]
    singbox = {"outbounds": [
        {"type": "selector", "tag": "proxy", "outbounds": ["auto"] + tags, "default": "auto"},
        {"type": "urltest", "tag": "auto", "outbounds": tags, "url": "https://www.gstatic.com/generate_204",
         "interval": "10m"},
        *[{**n.outbound, "tag": n.name} for n in ordered],
    ]}
    with open(f"{OUT_DIR}/singbox.json", "w", encoding="utf-8") as f:
        json.dump(singbox, f, ensure_ascii=False, indent=1)

    for n in nodes:
        if n.source in stats["sources"]:
            stats["sources"][n.source]["alive"] += 1
    stats.update({
        "test_mode": mode,
        "alive": len(nodes),
        "published": len(ordered),
        "fastest_ms": round(fastest_first[0].latency) if fastest_first else None,
        "median_ms": round(fastest_first[len(fastest_first) // 2].latency) if fastest_first else None,
        "countries": {countries.name(c): len(by_country[c]) for c in order},
        "protocols": dict(Counter(n.proto for n in ordered)),
    })
    with open(f"{OUT_DIR}/stats.json", "w", encoding="utf-8") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)
    write_readme(stats)


def write_readme(s: dict):
    rows = "\n".join(f"| {c} | {k} |" for c, k in s["countries"].items())
    src = "\n".join(f"| {u} | {v['links']} | {v['parsed']} | {v['new_unique']} | {v['alive']} |"
                    for u, v in s["sources"].items())
    with open(f"{OUT_DIR}/README.md", "w", encoding="utf-8") as f:
        f.write(f"""# Subscription status

Updated: **{s['last_run_utc']} UTC** · test: `{s['test_mode']}` · published **{s['published']}** \
of {s['alive']} alive / {s['unique']} unique · fastest {s['fastest_ms']} ms · median {s['median_ms']} ms

## Countries
| Country | Configs |
|---|---|
{rows}

## Sources
| Source | Links | Parsed | New unique | Alive |
|---|---|---|---|---|
{src}
""")


# ---------------------------------------------------------------- source health

HEALTH_URL = os.environ.get("HEALTH_URL", "")
DISCOVER_FILE = "discover.txt"
DEAD_AFTER_RUNS = 8          # consecutive runs with 0 alive -> source paused
RETRY_EVERY_RUNS = 48        # paused sources are retried about every 12 hours
PROMOTE_AFTER_RUNS = 3       # candidate with enough alive configs this many runs -> active
PROMOTE_MIN_ALIVE = 10


def load_health() -> dict:
    if not HEALTH_URL:
        return {}
    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=FETCH_TIMEOUT) as r:
            return json.loads(r.read().decode("utf-8"))
    except Exception:
        return {}


def pick_sources(base: list[str], candidates: list[str], health: dict) -> tuple[list[str], list[str]]:
    """Active = listed + promoted candidates, minus paused dead ones (retried now and then).
    Unpromoted candidates are probed too so good new sources are found automatically."""
    run = health.get("_run", 0) + 1
    health["_run"] = run
    chosen, paused = [], []
    for url in dict.fromkeys(base + candidates):
        h = health.get(url, {})
        # Sources carrying preferred-country nodes are never paused (default 1: unknown -> fetch once to learn).
        if h.get("zero_runs", 0) >= DEAD_AFTER_RUNS and run % RETRY_EVERY_RUNS and not h.get("pref_hints", 1):
            paused.append(url)
            continue
        chosen.append(url)
    return chosen, paused


def update_health(health: dict, stats: dict, candidates: list[str]):
    for url, s in stats["sources"].items():
        h = health.setdefault(url, {"zero_runs": 0, "good_runs": 0})
        alive = s["alive"]
        h["zero_runs"] = 0 if alive else h.get("zero_runs", 0) + 1
        if url in candidates:
            h["good_runs"] = h.get("good_runs", 0) + 1 if alive >= PROMOTE_MIN_ALIVE else 0
            h["promoted"] = h["good_runs"] >= PROMOTE_AFTER_RUNS or h.get("promoted", False)
        h["last_alive"] = alive
        h["pref_hints"] = s.get("pref_hints", 0)


def main():
    with open(SOURCES_FILE, encoding="utf-8") as f:
        base = [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
    candidates = []
    if os.path.exists(DISCOVER_FILE):
        with open(DISCOVER_FILE, encoding="utf-8") as f:
            candidates = [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
    health = load_health()
    sources, paused = pick_sources(base, candidates, health)
    stats = {"last_run_utc": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime()), "sources": {}, "paused_sources": paused}

    print(f"Fetching {len(sources)} sources...")
    nodes = collect(sources, stats)
    stats["unique"] = len(nodes)
    print(f"Unique parsed configs: {len(nodes)}")

    print("TCP pre-filter...")
    tcp_alive = asyncio.run(tcp_filter(nodes))
    hint_countries(tcp_alive)
    for n in tcp_alive:
        if n.hint in PREFERRED_COUNTRIES and n.source in stats["sources"]:
            stats["sources"][n.source]["pref_hints"] = stats["sources"][n.source].get("pref_hints", 0) + 1
    log_countries("tcp-alive (guessed)", (n.hint for n in tcp_alive))
    candidates = pick_candidates(tcp_alive)
    log_countries("candidates (guessed)", (n.hint for n in candidates))
    print(f"Candidates for real test: {len(candidates)}")

    if SINGBOX:
        print(f"Real proxy test with {SINGBOX}...")
        alive, mode = real_test(candidates), "sing-box (real HTTPS through proxy)"
    else:
        print("WARNING: sing-box not found - falling back to TCP-only results")
        alive = [n for n in candidates if n.tcp_ms is not None]
        for n in alive:
            n.latency = n.tcp_ms
        mode = "tcp-only"

    alive = compat_filter(alive)
    geo_fallback(alive)
    log_countries("alive (real exit country)", (n.country for n in alive))
    print(f"Alive: {len(alive)}")
    publish(alive, stats, mode)
    update_health(health, stats, candidates)
    with open(f"{OUT_DIR}/health.json", "w", encoding="utf-8") as f:
        json.dump(health, f, indent=1)
    print(f"Paused dead sources: {len(paused)}")
    print("Done.")


if __name__ == "__main__":
    main()
