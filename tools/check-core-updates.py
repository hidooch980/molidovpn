#!/usr/bin/env python3
"""Checks upstream releases of the Android cores and rewrites the pins in tools/fetch-binaries.sh.

Stdlib only (plus the gh CLI for publishing the mirror release). Used by .github/workflows/core-updates.yml,
runs locally too:

  python tools/check-core-updates.py            # dry run, prints what it would do
  python tools/check-core-updates.py --apply    # rewrite pins, publish binaries-N+1 (needs GH_TOKEN/gh auth)

Only writes to this repository (hidooch980/molidovpn-android) with the workflow's own GITHUB_TOKEN.
hidooch980/mobin-vpn's core-updates workflow notices commits starting with "Core update (Android)" and
starts its release.

Safety policy (auto-apply only non-breaking updates, never pre-releases):
  sing-box   same major.minor as the current pin (1.12.x patches); a new minor/major opens an issue here
  Xray-core  any newer stable release -> new mirror release binaries-N+1 with the new libxray.so
  Tor / lyrebird / Psiphon AAR come from the upstream core mirror and are not updated automatically.

A version is attempted at most once per 24 h (state: .github/core-versions.json), so a failing build does
not cause a retry loop.

Outputs a JSON summary (--summary): {"commit": "...", "applied": [...], "review": [...], "errors": [...]}
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

REPO = "hidooch980/molidovpn-android"
RETRY_WINDOW = dt.timedelta(hours=24)


# ---------------------------------------------------------------- versions

def parse_version(tag: str) -> tuple[int, ...] | None:
    """'v1.12.25' -> (1, 12, 25). Pre-release tags ('1.15.0-alpha.4', 'rc') -> None."""
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


def newest_stable(tags: list[str], prefix_minor: tuple[int, ...] | None = None) -> str | None:
    best = None
    for t in tags:
        v = parse_version(t)
        if v is None or (prefix_minor and v[:2] != prefix_minor):
            continue
        if best is None or is_newer(t, best):
            best = t
    return best


# ---------------------------------------------------------------- pins (fetch-binaries.sh)

RX_SB_VER = r'^(SINGBOX_VERSION=")([^"]*)(")'
RX_BIN_TAG = r'(\$\{BINARIES_TAG:-)(binaries-\d+)(\})'


def rx_sb_sha(abi: str) -> str:
    return r"^(\s*" + re.escape(abi) + r"\) echo )([0-9a-f]{64})( ;;)"


def pin_group(pattern: str, text: str, what: str) -> str:
    m = list(re.finditer(pattern, text, flags=re.M))
    if len(m) != 1:
        raise ValueError(f"expected exactly one {what} pin, found {len(m)}")
    return m[0].group(2)


def set_pin(pattern: str, value: str, text: str, what: str) -> str:
    def repl(m: re.Match) -> str:
        return m.group(1) + value + m.group(3)
    new, n = re.subn(pattern, repl, text, flags=re.M)
    if n != 1:
        raise ValueError(f"expected exactly one {what} pin, found {n}")
    return new


# ---------------------------------------------------------------- network

def http_get(url: str, accept: str | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "molido-core-updates"})
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok and "api.github.com" in url:
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


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stable_releases(repo: str) -> list[dict]:
    rels = gh_api(f"repos/{repo}/releases?per_page=30")
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
    return bool(ts) and now - dt.datetime.fromisoformat(ts) < RETRY_WINDOW


def record(state: dict, component: str, version: str, now: dt.datetime, applied: bool = True) -> None:
    c = state.setdefault("components", {}).setdefault(component, {})
    c.setdefault("attempts", {})[version] = now.isoformat(timespec="seconds")
    c["attempts"] = dict(sorted(c["attempts"].items(), key=lambda kv: kv[1])[-10:])
    if applied:
        c["applied"] = version


# ---------------------------------------------------------------- checks

class Ctx:
    def __init__(self, args):
        self.args = args
        self.now = dt.datetime.now(dt.timezone.utc)
        self.state = load_state(args.state)
        with open(args.fetch_sh, encoding="utf-8", newline="") as f:
            self.sh = f.read()
        self.changes: list[str] = []
        self.review: list[dict] = []
        self.mirror_replace: dict[str, bytes] = {}

    def skip_recent(self, component: str, version: str) -> bool:
        if recently_attempted(self.state, component, version, self.now):
            print(f"{component} {version}: already attempted in the last 24 h, skipping")
            return True
        return False


# libxray.so in the mirror release is the plain xray executable per ABI.
XRAY_ASSETS = {"arm64-v8a__libxray.so": "Xray-android-arm64-v8a.zip",
               "armeabi-v7a__libxray.so": "Xray-linux-arm32-v7a.zip"}


def check_xray(ctx: Ctx) -> None:
    rels = stable_releases("XTLS/Xray-core")
    latest = newest_stable([r["tag_name"] for r in rels])
    cur = ctx.state.get("components", {}).get("xray", {}).get("applied")
    if not latest:
        print("Xray: no stable release found")
        return
    # No recorded version yet: the mirror holds the upstream core build of unknown version -> adopt latest once.
    if cur and not is_newer(latest, cur):
        print(f"Xray: {cur} is current")
        return
    if ctx.skip_recent("xray", latest):
        return
    rel = next(r for r in rels if r["tag_name"] == latest)
    if ctx.args.apply:
        for mirror_name, zname in XRAY_ASSETS.items():
            z = zipfile.ZipFile(io.BytesIO(download_verified_dgst(rel, zname)))
            ctx.mirror_replace[mirror_name] = z.read("xray")
    else:
        print(f"Xray: would mirror {latest} ({', '.join(XRAY_ASSETS.values())})")
    ctx.changes.append(f"Xray {cur or 'mirror build'} → {latest}")
    record(ctx.state, "xray", latest, ctx.now)


def check_singbox(ctx: Ctx) -> None:
    rels = stable_releases("SagerNet/sing-box")
    tags = [r["tag_name"] for r in rels]
    base = pin_group(RX_SB_VER, ctx.sh, "SINGBOX_VERSION")
    newest = newest_stable(tags)
    if newest and not same_minor(newest, base) and is_newer(newest, base):
        # Owner decision: new sing-box minors are ignored (no issue); only patches of the pinned series.
        print(f"sing-box: {newest} ignored; staying on {base} series")
    patch = newest_stable(tags, parse_version(base)[:2])
    if not patch or not is_newer(patch, base):
        print(f"sing-box: {base} is current in its series")
        return
    ver = patch.lstrip("v")
    if ctx.skip_recent("sing-box-android", ver):
        return
    rel = next(r for r in rels if r["tag_name"] == patch)
    sh = set_pin(RX_SB_VER, ver, ctx.sh, "SINGBOX_VERSION")
    for abi, arch in (("arm64-v8a", "arm64"), ("armeabi-v7a", "arm")):
        name = f"sing-box-{ver}-android-{arch}.tar.gz"
        url = asset_url(rel, name)
        if not url:
            raise RuntimeError(f"sing-box {ver}: {name} missing")
        if ctx.args.apply:
            data = http_get(url)
            if len(data) < 1_000_000 or data[:2] != b"\x1f\x8b":
                raise RuntimeError(f"{name}: not a gzip tarball")
            sh = set_pin(rx_sb_sha(abi), sha256(data), sh, f"sing-box {abi} sha")
    ctx.sh = sh
    ctx.changes.append(f"sing-box {base} → {ver}")
    record(ctx.state, "sing-box-android", ver, ctx.now)


# ---------------------------------------------------------------- mirror + issues

def gh(*args: str, capture: bool = False) -> str:
    r = subprocess.run(["gh", *args], check=True, capture_output=capture, text=True)
    return r.stdout if capture else ""


def publish_mirror(ctx: Ctx) -> None:
    """Copies the current mirror release, replaces changed assets, publishes binaries-N+1."""
    cur_tag = pin_group(RX_BIN_TAG, ctx.sh, "BINARIES_TAG")
    tags = gh("release", "list", "-R", REPO, "--limit", "200", "--json", "tagName",
              "--jq", ".[].tagName", capture=True).split()
    n = max([int(t.split("-")[1]) for t in tags if re.fullmatch(r"binaries-\d+", t)] + [0]) + 1
    new_tag = f"binaries-{n}"
    work = tempfile.mkdtemp()
    try:
        gh("release", "download", cur_tag, "-R", REPO, "-D", work)
        # Verify what we copy forward.
        with open(os.path.join(work, "SHA256SUMS.txt"), encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2:
                    with open(os.path.join(work, parts[1].lstrip("*")), "rb") as fh:
                        if sha256(fh.read()) != parts[0].lower():
                            raise RuntimeError(f"{cur_tag}: checksum mismatch for {parts[1]}")
        for name, data in ctx.mirror_replace.items():
            with open(os.path.join(work, name), "wb") as f:
                f.write(data)
        files = sorted(f for f in os.listdir(work) if f != "SHA256SUMS.txt")
        with open(os.path.join(work, "SHA256SUMS.txt"), "w", newline="\n") as out:
            for f in files:
                with open(os.path.join(work, f), "rb") as fh:
                    out.write(f"{sha256(fh.read())} *{f}\n")
        notes = (f"Copy of {cur_tag} with updated: {', '.join(sorted(ctx.mirror_replace))} "
                 f"({'; '.join(ctx.changes)}). SHA256SUMS.txt lists the checksums.")
        gh("release", "create", new_tag, "-R", REPO, "--title", f"Prebuilt binaries {n}",
           "--notes", notes, "--latest=false", *[os.path.join(work, f) for f in files + ["SHA256SUMS.txt"]])
    finally:
        shutil.rmtree(work, ignore_errors=True)
    ctx.sh = set_pin(RX_BIN_TAG, new_tag, ctx.sh, "BINARIES_TAG")
    ctx.sh = ctx.sh.replace(f'our own release "{cur_tag}"', f'our own release "{new_tag}"')


def upsert_issue(title: str, body: str) -> None:
    out = gh("issue", "list", "-R", REPO, "--state", "open", "--search", f'"{title}" in:title',
             "--json", "number,title", capture=True)
    for i in json.loads(out or "[]"):
        if i["title"] == title:
            gh("issue", "edit", str(i["number"]), "-R", REPO, "--body", body)
            print(f"issue #{i['number']} refreshed: {title}")
            return
    gh("issue", "create", "-R", REPO, "--title", title, "--body", body)


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch-sh", default="tools/fetch-binaries.sh")
    ap.add_argument("--state", default=".github/core-versions.json")
    ap.add_argument("--apply", action="store_true", help="write files, publish mirror, open issues")
    ap.add_argument("--summary", default="core-updates-summary.json")
    args = ap.parse_args()

    ctx = Ctx(args)
    errors = []
    for check in (check_singbox, check_xray):
        try:
            check(ctx)
        except Exception as e:  # one broken upstream must not block the other
            errors.append(f"{check.__name__}: {e}")
            print(f"::warning::{check.__name__} failed: {e}")

    if args.apply:
        if ctx.mirror_replace:
            publish_mirror(ctx)
        if ctx.changes:
            with open(args.fetch_sh, "w", encoding="utf-8", newline="") as f:
                f.write(ctx.sh)
        with open(args.state, "w", encoding="utf-8", newline="\n") as f:
            json.dump(ctx.state, f, indent=2, sort_keys=True)
            f.write("\n")
        for r in ctx.review:
            try:
                upsert_issue(r["title"], r["body"])
            except Exception as e:
                errors.append(f"issue: {e}")

    summary = {
        "commit": ("Core update (Android): " + "; ".join(ctx.changes)) if ctx.changes else "",
        "applied": ctx.changes,
        "review": [r["title"] for r in ctx.review],
        "errors": errors,
    }
    with open(args.summary, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
