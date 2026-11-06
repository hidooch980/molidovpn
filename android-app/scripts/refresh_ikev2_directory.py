#!/usr/bin/env python3
"""Refresh the public, non-secret IKEv2 endpoint mirror from VPN Jantit's public pages."""
from __future__ import annotations

import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

BASE = "https://www.vpnjantit.com/"
INDEX = urljoin(BASE, "free-ikev2")
HOST = "www.vpnjantit.com"
OUT = Path("data/ikev2/free-servers.json")
HOST_RE = re.compile(r"(?i)\b([a-z0-9-]+\.vpnjantit\.com)\b")
PAGE_RE = re.compile(r"^/free-ikev2-[a-z0-9-]+$")
CODE_RE = re.compile(r"^[a-z0-9-]{1,63}$")
MAX_COUNTRY_PAGES = 80
MAX_PAGE_BYTES = 2 * 1024 * 1024
MAX_FETCH_ATTEMPTS = 4
MAX_RETRY_AFTER_SECONDS = 10


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.href = None
        self.text = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.href = dict(attrs).get("href")
            self.text = []

    def handle_data(self, data):
        if self.href is not None:
            self.text.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self.href is not None:
            self.links.append((self.href, " ".join(self.text).strip()))
            self.href = None
            self.text = []


def is_provider_url(url: str) -> bool:
    """Reject userinfo, non-HTTPS, alternate hosts/ports and fragments."""
    try:
        parsed = urlparse(url)
        return (
            parsed.scheme == "https"
            and parsed.hostname == HOST
            and parsed.username is None
            and parsed.password is None
            and parsed.port in (None, 443)
            and parsed.fragment == ""
        )
    except ValueError:
        return False


def _retry_delay(error: Exception, attempt: int) -> float:
    retry_after = None
    if isinstance(error, HTTPError):
        retry_after = error.headers.get("Retry-After") if error.headers else None
    if retry_after:
        try:
            return min(MAX_RETRY_AFTER_SECONDS, max(0.0, float(retry_after)))
        except ValueError:
            pass
    return min(MAX_RETRY_AFTER_SECONDS, float(2 ** attempt))


def _is_transient_fetch_error(error: Exception) -> bool:
    if isinstance(error, HTTPError):
        return error.code == 429 or 500 <= error.code <= 599
    return isinstance(error, (URLError, TimeoutError, ConnectionError))


def get(url: str) -> str:
    if not is_provider_url(url):
        raise RuntimeError(f"Refusing non-provider URL: {url}")
    req = Request(url, headers={"User-Agent": "MolidoVPN-IKEv2-directory/1.1"})
    for attempt in range(MAX_FETCH_ATTEMPTS):
        try:
            with urlopen(req, timeout=20) as response:
                final = response.geturl()
                if not is_provider_url(final):
                    raise RuntimeError(f"Refusing non-provider redirect: {final}")
                data = response.read(MAX_PAGE_BYTES + 1)
                if len(data) > MAX_PAGE_BYTES:
                    raise RuntimeError("Provider page exceeds size limit")
                return data.decode("utf-8", errors="replace")
        except Exception as exc:
            if not _is_transient_fetch_error(exc) or attempt == MAX_FETCH_ATTEMPTS - 1:
                raise
            time.sleep(_retry_delay(exc, attempt))
    raise RuntimeError("Provider fetch exhausted retries")


def extract_index_pages(html: str) -> list[tuple[str, str]]:
    parser = Links()
    parser.feed(html)
    pages = []
    for href, label in parser.links:
        absolute = urljoin(INDEX, href)
        parsed = urlparse(absolute)
        if not is_provider_url(absolute) or not PAGE_RE.fullmatch(parsed.path.rstrip("/")):
            continue
        country = label.replace("IKEV2 MSCHPv2 ", "").strip()
        if country:
            pages.append((country, absolute))
    return list(dict.fromkeys(pages))


def extract_country_servers(country: str, page_url: str, html: str) -> list[dict]:
    if not is_provider_url(page_url):
        raise RuntimeError("Country page is not on the provider's HTTPS origin")
    parser = Links()
    parser.feed(html)
    account_links = {}
    for href, _ in parser.links:
        absolute = urljoin(page_url, href)
        parsed = urlparse(absolute)
        if not is_provider_url(absolute) or not parsed.path.startswith("/create-free-account"):
            continue
        code = parse_qs(parsed.query).get("server", [""])[0].lower()
        if CODE_RE.fullmatch(code):
            account_links[code] = absolute

    plain = re.sub(r"<[^>]+>", " ", html)
    plain = re.sub(r"\s+", " ", plain)
    available = bool(re.search(r"\bAvailable\b", plain, re.I)) and not bool(
        re.search(r"\b(Not Available|Unavailable)\b", plain, re.I)
    )
    servers = []
    for gateway in sorted(set(HOST_RE.findall(plain))):
        gateway = gateway.lower()
        code = gateway.split(".", 1)[0]
        if code not in account_links:
            continue
        servers.append({
            "country": country,
            "host": gateway,
            "identity": "vpnjantit",
            "accountUrl": account_links[code],
            "available": available,
        })
    return servers


def build_directory(index_html: str, fetch_country=get) -> dict:
    pages = extract_index_pages(index_html)
    if not pages:
        raise RuntimeError("No recognized IKEv2 country pages; refusing to overwrite last-known-good mirror")
    if len(pages) > MAX_COUNTRY_PAGES:
        raise RuntimeError(f"Provider returned {len(pages)} country pages; safety limit is {MAX_COUNTRY_PAGES}")

    servers = {}
    failures = []
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = {
            pool.submit(fetch_country, url): (country, url)
            for country, url in pages
        }
        for future in as_completed(futures):
            country, url = futures[future]
            try:
                for item in extract_country_servers(country, url, future.result()):
                    servers[item["host"]] = item
            except Exception as exc:
                failures.append(f"{country}: {exc}")

    # Never replace a last-known-good snapshot with a partial scrape.
    if failures:
        raise RuntimeError("Incomplete provider scrape; mirror preserved: " + "; ".join(failures[:5]))
    if not servers:
        raise RuntimeError("No valid IKEv2 endpoints found; refusing to overwrite last-known-good mirror")

    return {
        "schema": 1,
        "source": INDEX,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "servers": sorted(servers.values(), key=lambda item: (item["country"].lower(), item["host"])),
    }


def main() -> None:
    payload = build_directory(get(INDEX))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(payload['servers'])} endpoints to {OUT}")


if __name__ == "__main__":
    main()
