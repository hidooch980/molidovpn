#!/usr/bin/env python3
"""Checks upstream releases of the bundled Windows cores/tunnels and rewrites tools/core-pins.json.

Stdlib only. Used by .github/workflows/core-updates.yml, but runs locally too:

  python tools/check-core-updates.py            # dry run, prints what it would do
  python tools/check-core-updates.py --apply    # rewrite tools/core-pins.json, open issues

Never edits .github/workflows/* (GITHUB_TOKEN may not push workflow files): release.yml reads the pins
from tools/core-pins.json at build time. Android pins live in hidooch980/molidovpn-android, which has its
own core-updates workflow; this repo only notices its "Core update (Android)" commits and starts a release.

Environment:
  GITHUB_TOKEN       token for API calls and issues in mobin-vpn

Safety policy (auto-apply only non-breaking updates, never pre-releases):
  sing-box   Windows takes the newest patch of SINGBOX_WINDOWS_MINOR at build time; a new minor/major
             only opens an issue
  Xray-core  any newer stable release
  Tor        newest stable Tor Browser version on dist.torproject.org
  Psiphon    newer commit touching windows/psiphon-tunnel-core-i686.exe
  AmneziaWG  newer stable release
  Upstream core (Rust core / Android mirror) never merged automatically, only reported

Outputs a JSON summary (--summary) consumed by the workflow:
  {"mobin_commit": "...", "review": [...], "report": [...], "errors": [...]}
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

MOBIN_REPO = "hidooch980/molidovpn"
RETRY_WINDOW = dt.timedelta(hours=24)
ISSUE_TITLE_REPORT = "Core updates: manual follow-up"


# ---------------------------------------------------------------- versions

def parse_version(tag: str) -> tuple[int, ...] | None:
    """'v1.12.25' -> (1, 12, 25). Pre-release tags ('1.15.0-alpha.4', '15.0a2', 'rc') -> None."""
    t = tag.strip()
    if t[:1] in "vV":
        t = t[1:]
    if not re.fullmatch(r"\d+(\.\d+)*", t):
        return None
    return tuple(int(p) for p in t.split("."))


def is_newer(candidate: str, current: str) -> bool:
    c, o = parse_version(candidate), parse_version(current)
    if c is None or o is None:
        return False
    n = max(len(c), len(o))
    return c + (0,) * (n - len(c)) > o + (0,) * (n - len(o))


def same_minor(a: str, b: str) -> bool:
    x, y = parse_version(a), parse_version(b)
    return x is not None and y is not None and x[:2] == y[:2]


def newest_stable(tags: list[str], prefix_minor: tuple[int, int] | None = None) -> str | None:
    best = None
    for t in tags:
        v = parse_version(t)
        if v is None or (prefix_minor and v[:2] != prefix_minor):
            continue
        if best is None or is_newer(t, best):
            best = t
    return best


# ---------------------------------------------------------------- pins (tools/core-pins.json)

def pin_get(pins: dict, key: str) -> str:
    if key not in pins:
        raise ValueError(f"tools/core-pins.json has no {key}")
    return pins[key]


# ---------------------------------------------------------------- network

def _token_for(url: str) -> str | None:
    if "api.github.com" in url:
        return os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    return None


def http_get(url: str, accept: str | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "molido-core-updates"})
    tok = _token_for(url)
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    if accept:
        req.add_header("Accept", accept)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.read()
        except urllib.error.HTTPError:
            raise
        except Exception:
            if attempt == 2:
                raise
    raise AssertionError("unreachable")


def gh_api(path: str):
    return json.loads(http_get("https://api.github.com/" + path.lstrip("/"), "application/vnd.github+json"))


def gh_api_write(method: str, path: str, body: dict):
    req = urllib.request.Request("https://api.github.com/" + path.lstrip("/"), method=method,
                                 data=json.dumps(body).encode(),
                                 headers={"User-Agent": "molido-core-updates",
                                          "Accept": "application/vnd.github+json",
                                          "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"{}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stable_releases(repo: str) -> list[dict]:
    rels = gh_api(f"repos/{repo}/releases?per_page=30")   # asset lists make big pages slow
    return [r for r in rels if not r.get("prerelease") and not r.get("draft")]


def asset_url(release: dict, name: str) -> str | None:
    for a in release.get("assets", []):
        if a["name"] == name:
            return a["browser_download_url"]
    return None


def download_verified_dgst(release: dict, name: str) -> bytes:
    """Downloads an Xray asset and checks it against the release's .dgst file."""
    url = asset_url(release, name)
    dgst_url = asset_url(release, name + ".dgst")
    if not url or not dgst_url:
        raise RuntimeError(f"{release['tag_name']}: {name} or its .dgst is missing")
    data = http_get(url)
    m = re.search(r"SHA2-256=\s*([0-9a-f]{64})", http_get(dgst_url).decode())
    if not m or m.group(1) != sha256(data):
        raise RuntimeError(f"{name}: SHA-256 does not match the published .dgst")
    return data


# ---------------------------------------------------------------- state

def load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"components": {}}


def recently_attempted(state: dict, component: str, version: str, now: dt.datetime) -> bool:
    ts = state.get("components", {}).get(component, {}).get("attempts", {}).get(version)
    if not ts:
        return False
    return now - dt.datetime.fromisoformat(ts) < RETRY_WINDOW


def record(state: dict, component: str, version: str, now: dt.datetime, applied: bool = True) -> None:
    c = state.setdefault("components", {}).setdefault(component, {})
    c.setdefault("attempts", {})[version] = now.isoformat(timespec="seconds")
    # Keep the attempts map small.
    c["attempts"] = dict(sorted(c["attempts"].items(), key=lambda kv: kv[1])[-10:])
    if applied:
        c["applied"] = version


# ---------------------------------------------------------------- checks

class Ctx:
    def __init__(self, args):
        self.args = args
        self.now = dt.datetime.now(dt.timezone.utc)
        self.state = load_state(args.state)
        with open(args.pins, encoding="utf-8") as f:
            self.pins = json.load(f)
        self.mobin_changes: list[str] = []
        self.review: list[dict] = []   # {"title": ..., "body": ...} -> one issue each
        self.report: list[str] = []    # lines for the manual follow-up issue

    def skip_recent(self, component: str, version: str) -> bool:
        if recently_attempted(self.state, component, version, self.now):
            print(f"{component} {version}: already attempted in the last 24 h, skipping")
            return True
        return False


def check_xray(ctx: Ctx) -> None:
    cur = pin_get(ctx.pins, "XRAY_VERSION")
    rels = stable_releases("XTLS/Xray-core")
    latest = newest_stable([r["tag_name"] for r in rels])
    if not latest or not is_newer(latest, cur):
        print(f"Xray: {cur} is current")
        return
    if ctx.skip_recent("xray", latest):
        return
    rel = next(r for r in rels if r["tag_name"] == latest)
    win = download_verified_dgst(rel, "Xray-windows-64.zip")
    ctx.pins["XRAY_VERSION"] = latest
    ctx.pins["XRAY_SHA256"] = sha256(win)
    ctx.mobin_changes.append(f"Xray {cur} → {latest}")
    record(ctx.state, "xray", latest, ctx.now)


def check_singbox(ctx: Ctx) -> None:
    rels = stable_releases("SagerNet/sing-box")
    newest = newest_stable([r["tag_name"] for r in rels])
    minor = pin_get(ctx.pins, "SINGBOX_WINDOWS_MINOR")
    base = minor + ".0"
    if newest and not same_minor(newest, base) and is_newer(newest, base):
        # Owner decision: new sing-box minors are ignored (no issue); only patches of the pinned series.
        print(f"sing-box: {newest} ignored; staying on {minor}.x")
    else:
        print(f"sing-box: {minor}.x is the newest series")


def _commit_date(repo: str, sha: str) -> str:
    return gh_api(f"repos/{repo}/commits/{sha}")["commit"]["committer"]["date"]


def check_psiphon(ctx: Ctx) -> None:
    repo = "Psiphon-Labs/psiphon-tunnel-core-binaries"
    cur = pin_get(ctx.pins, "PSIPHON_COMMIT")
    cur_date = _commit_date(repo, cur)
    latest = gh_api(f"repos/{repo}/commits?path=windows/psiphon-tunnel-core-i686.exe&per_page=1")[0]
    sha, date = latest["sha"], latest["commit"]["committer"]["date"]
    if sha != cur and date > cur_date and not ctx.skip_recent("psiphon", sha):
        data = http_get(f"https://raw.githubusercontent.com/{repo}/{sha}/windows/psiphon-tunnel-core-i686.exe")
        if len(data) < 1_000_000 or data[:2] != b"MZ":
            raise RuntimeError("Psiphon download is not a Windows executable")
        ctx.pins["PSIPHON_COMMIT"] = sha
        ctx.pins["PSIPHON_SHA256"] = sha256(data)
        ctx.mobin_changes.append(f"Psiphon {cur[:7]} → {sha[:7]}")
        record(ctx.state, "psiphon", sha, ctx.now)
    else:
        print(f"Psiphon (Windows): {cur[:7]} is current")
    # The Android AAR is updated automatically by hidooch980/molidovpn-android's core-updates workflow.


def check_tor(ctx: Ctx) -> None:
    cur = pin_get(ctx.pins, "TOR_BROWSER_VERSION")
    index = http_get("https://dist.torproject.org/torbrowser/").decode("utf-8", "replace")
    versions = re.findall(r'href="(\d+\.\d+(?:\.\d+)*)/"', index)   # alphas look like 15.0a2 -> excluded
    latest = newest_stable(versions)
    if not latest or not is_newer(latest, cur):
        print(f"Tor: {cur} is current")
        return
    if ctx.skip_recent("tor", latest):
        return
    base = f"https://dist.torproject.org/torbrowser/{latest}"
    name = f"tor-expert-bundle-windows-x86_64-{latest}.tar.gz"
    expected = None
    for sums in ("sha256sums-signed-build.txt", "sha256sums-unsigned-build.txt"):
        try:
            text = http_get(f"{base}/{sums}").decode()
        except Exception:
            continue
        for line in text.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1].lstrip("*") == name:
                expected = parts[0].lower()
        if expected:
            break
    if not expected:
        print(f"Tor {latest}: no published checksum yet, trying later")
        return
    actual = sha256(http_get(f"{base}/{name}"))
    if actual != expected:
        raise RuntimeError(f"Tor {latest}: SHA-256 mismatch {actual} vs {expected}")
    ctx.pins["TOR_BROWSER_VERSION"] = latest
    ctx.pins["TOR_BUNDLE_SHA256"] = actual
    ctx.mobin_changes.append(f"Tor {cur} → {latest}")
    record(ctx.state, "tor", latest, ctx.now)
    ctx.report.append(f"- Android: Tor {latest} is out; `libtor.so` / `libobfs4proxy.so` come from the "
                      "upstream core mirror and are not rebuilt automatically.")


def check_amneziawg(ctx: Ctx) -> None:
    cur = pin_get(ctx.pins, "AWG_VERSION")
    rels = stable_releases("amnezia-vpn/amneziawg-windows-client")
    latest = newest_stable([r["tag_name"] for r in rels])
    if not latest or not is_newer(latest, cur):
        print(f"AmneziaWG: {cur} is current")
        return
    if ctx.skip_recent("amneziawg", latest):
        return
    rel = next(r for r in rels if r["tag_name"] == latest)
    url = asset_url(rel, f"amneziawg-amd64-{latest}.msi")
    if not url:   # the release.yml URL scheme assumes tag == version == asset suffix
        ctx.review.append({"title": f"Core update needs review: AmneziaWG {latest}",
                           "body": f"Release {latest} has no `amneziawg-amd64-{latest}.msi` asset; "
                                   "the download step in release.yml needs adjusting."})
        record(ctx.state, "amneziawg", latest, ctx.now, applied=False)
        return
    ctx.pins["AWG_VERSION"] = latest
    ctx.pins["AWG_MSI_SHA256"] = sha256(http_get(url))
    ctx.mobin_changes.append(f"AmneziaWG {cur} → {latest}")
    record(ctx.state, "amneziawg", latest, ctx.now)


UPSTREAM_CORE_REPO = "mbm110/MSN-GUARD"


def check_upstream_core(ctx: Ctx) -> None:
    rels = stable_releases(UPSTREAM_CORE_REPO)
    latest = newest_stable([r["tag_name"] for r in rels])
    comps = ctx.state.setdefault("components", {})
    legacy = comps.pop("msn-guard", None)  # old state key name; carry its value over
    comp = comps.setdefault("android-upstream", legacy or {})
    seen = comp.get("seen")
    if latest and (seen is None or is_newer(latest, seen)):
        ctx.report.append(f"- Upstream core (Rust core / Android mirror) released {latest}"
                          f" (last seen: {seen or 'none'}). Not merged automatically: review the code "
                          "and license before porting core changes or refreshing mirrored binaries.")
        comp["seen"] = latest


# ---------------------------------------------------------------- issues

def upsert_issue(title: str, body: str) -> None:
    q = gh_api(f"repos/{MOBIN_REPO}/issues?state=open&per_page=100")
    for i in q:
        if i.get("title") == title and "pull_request" not in i:
            if i.get("body") != body:
                gh_api_write("PATCH", f"repos/{MOBIN_REPO}/issues/{i['number']}", {"body": body})
            print(f"issue #{i['number']} refreshed: {title}")
            return
    r = gh_api_write("POST", f"repos/{MOBIN_REPO}/issues", {"title": title, "body": body})
    print(f"issue #{r.get('number')} opened: {title}")


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pins", default="tools/core-pins.json")
    ap.add_argument("--state", default=".github/core-versions.json")
    ap.add_argument("--apply", action="store_true", help="write pins/state, open issues")
    ap.add_argument("--summary", default="core-updates-summary.json")
    args = ap.parse_args()

    ctx = Ctx(args)
    errors = []
    for check in (check_xray, check_singbox, check_psiphon, check_tor, check_amneziawg, check_upstream_core):
        try:
            check(ctx)
        except Exception as e:  # one broken upstream must not block the others
            errors.append(f"{check.__name__}: {e}")
            print(f"::warning::{check.__name__} failed: {e}")

    if args.apply:
        if ctx.mobin_changes:
            with open(args.pins, "w", encoding="utf-8", newline="\n") as f:
                json.dump(ctx.pins, f, indent=2, sort_keys=True)
                f.write("\n")
        # No timestamp here: an unchanged file means nothing to commit.
        with open(args.state, "w", encoding="utf-8", newline="\n") as f:
            json.dump(ctx.state, f, indent=2, sort_keys=True)
            f.write("\n")
        if os.environ.get("GITHUB_TOKEN"):
            for r in ctx.review:
                upsert_issue(r["title"], r["body"])
            if ctx.report:
                upsert_issue(ISSUE_TITLE_REPORT, "Detected by the core-updates workflow on "
                             f"{ctx.now:%Y-%m-%d %H:%M} UTC:\n\n" + "\n".join(ctx.report))

    summary = {
        "mobin_commit": ("Core update: " + "; ".join(ctx.mobin_changes)) if ctx.mobin_changes else "",
        "review": [r["title"] for r in ctx.review],
        "report": ctx.report,
        "errors": errors,
    }
    with open(args.summary, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
