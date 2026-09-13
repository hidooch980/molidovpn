"""Parse proxy share links into sing-box outbound objects and rename them."""

import base64
import json
from urllib.parse import parse_qs, quote, unquote, urlparse

SUPPORTED_PREFIXES = ("vless://", "vmess://", "trojan://", "ss://", "hysteria2://", "hy2://", "tuic://",
                      "anytls://", "wireguard://", "wg://", "socks://", "socks5://")
UDP_TYPES = {"hysteria2", "tuic", "wireguard"}
UTLS_FINGERPRINTS = {"chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized"}


def b64decode(text: str) -> str:
    text = text.strip().replace("-", "+").replace("_", "/")
    return base64.b64decode(text + "=" * (-len(text) % 4)).decode("utf-8", errors="strict")


def _q(query: dict, key: str, default: str = "") -> str:
    return query.get(key, [default])[0]


def _valid_endpoint(host, port) -> bool:
    try:
        return bool(host) and 0 < int(port) < 65536
    except (TypeError, ValueError):
        return False


def _tls(security: str, sni: str, host: str, alpn: str, fp: str, insecure: bool, pbk: str = "", sid: str = ""):
    if security not in ("tls", "reality"):
        return None
    tls = {"enabled": True, "server_name": sni or host, "insecure": insecure}
    if alpn:
        tls["alpn"] = [a for a in alpn.split(",") if a]
    if fp or security == "reality":
        tls["utls"] = {"enabled": True, "fingerprint": fp if fp in UTLS_FINGERPRINTS else "chrome"}
    if security == "reality":
        if not pbk:
            raise ValueError("reality without public key")
        tls["reality"] = {"enabled": True, "public_key": pbk, "short_id": sid}
    return tls


def _transport(net: str, path: str, host: str, service_name: str):
    net = (net or "tcp").lower()
    if net in ("tcp", "raw", ""):
        return None
    if net == "ws":
        t = {"type": "ws", "path": path or "/"}
        if "?ed=" in t["path"]:
            t["path"], _, ed = t["path"].partition("?ed=")
            if ed.isdigit():
                t["max_early_data"] = int(ed)
                t["early_data_header_name"] = "Sec-WebSocket-Protocol"
        if host:
            t["headers"] = {"Host": host}
        return t
    if net == "grpc":
        return {"type": "grpc", "service_name": service_name or path}
    if net in ("h2", "http"):
        t = {"type": "http", "path": path or "/"}
        if host:
            t["host"] = host.split(",")
        return t
    if net == "httpupgrade":
        return {"type": "httpupgrade", "path": path or "/", "host": host}
    raise ValueError(f"unsupported transport {net}")


def _finish(out: dict, tls, transport) -> dict:
    if tls:
        out["tls"] = tls
    if transport:
        out["transport"] = transport
    return out


def parse_vmess(uri: str) -> dict:
    d = json.loads(b64decode(uri[len("vmess://"):]))
    host, port = str(d.get("add", "")).strip(), d.get("port")
    if not _valid_endpoint(host, port) or not d.get("id"):
        raise ValueError("bad vmess")
    if str(d.get("type", "none")).lower() not in ("", "none") and d.get("net", "tcp") == "tcp":
        raise ValueError("vmess tcp header obfuscation unsupported")
    out = {
        "type": "vmess", "server": host, "server_port": int(port), "uuid": d["id"],
        "security": d.get("scy") or "auto", "alter_id": int(d.get("aid") or 0),
    }
    tls = _tls(str(d.get("tls", "")).lower(), d.get("sni", ""), d.get("host", "") or host,
               d.get("alpn", ""), d.get("fp", ""), False)
    return _finish(out, tls, _transport(d.get("net", "tcp"), d.get("path", ""), d.get("host", ""), d.get("path", "")))


def _common_url(uri: str):
    p = urlparse(uri)
    if not _valid_endpoint(p.hostname, p.port):
        raise ValueError("bad endpoint")
    userinfo = unquote(p.netloc.rsplit("@", 1)[0]) if "@" in p.netloc else ""
    return p, p.hostname, p.port, userinfo, parse_qs(p.query)


def parse_vless_trojan(uri: str) -> dict:
    p, host, port, user, q = _common_url(uri)
    if not user:
        raise ValueError("missing credential")
    kind = p.scheme
    out = {"type": kind, "server": host, "server_port": port}
    if kind == "vless":
        out["uuid"] = user
        flow = _q(q, "flow")
        if flow and flow != "xtls-rprx-vision":
            raise ValueError("unsupported flow")
        if flow:
            out["flow"] = flow
        out["packet_encoding"] = "xudp"
        security = _q(q, "security", "none")
    else:
        out["password"] = user
        security = _q(q, "security", "tls")
    if _q(q, "headerType") == "http":
        raise ValueError("tcp header obfuscation unsupported")
    insecure = _q(q, "allowInsecure") in ("1", "true") or _q(q, "insecure") in ("1", "true")
    tls = _tls(security, _q(q, "sni"), _q(q, "host") or host, _q(q, "alpn"), _q(q, "fp"), insecure,
               _q(q, "pbk"), _q(q, "sid"))
    transport = _transport(_q(q, "type", "tcp"), _q(q, "path"), _q(q, "host"), _q(q, "serviceName"))
    return _finish(out, tls, transport)


def parse_ss(uri: str) -> dict:
    body = uri[len("ss://"):].split("#", 1)[0]
    body, _, query = body.partition("?")
    if "plugin=" in query:
        raise ValueError("ss plugins unsupported")
    body = body.rstrip("/")
    if "@" in body:
        userinfo, hostport = body.rsplit("@", 1)
        userinfo = unquote(userinfo)
        if ":" not in userinfo:
            userinfo = b64decode(userinfo)
    else:
        userinfo, _, hostport = b64decode(body).rpartition("@")
    method, _, password = userinfo.partition(":")
    p = urlparse(f"ss://x@{hostport}")
    if not method or not password or not _valid_endpoint(p.hostname, p.port):
        raise ValueError("bad ss")
    return {"type": "shadowsocks", "server": p.hostname, "server_port": p.port, "method": method, "password": password}


def parse_hysteria2(uri: str) -> dict:
    p, host, port, user, q = _common_url(uri.replace("hy2://", "hysteria2://", 1))
    if not user:
        raise ValueError("missing password")
    out = {
        "type": "hysteria2", "server": host, "server_port": port, "password": user,
        "tls": {"enabled": True, "server_name": _q(q, "sni") or host, "insecure": _q(q, "insecure") in ("1", "true")},
    }
    if _q(q, "obfs") == "salamander":
        out["obfs"] = {"type": "salamander", "password": _q(q, "obfs-password")}
    return out


def parse_tuic(uri: str) -> dict:
    p, host, port, user, q = _common_url(uri)
    uuid, _, password = user.partition(":")
    if not uuid or not password:
        raise ValueError("bad tuic credential")
    tls = {"enabled": True, "server_name": _q(q, "sni") or host,
           "insecure": _q(q, "allow_insecure") in ("1", "true") or _q(q, "insecure") in ("1", "true"),
           "alpn": [a for a in (_q(q, "alpn") or "h3").split(",") if a]}
    return {"type": "tuic", "server": host, "server_port": port, "uuid": uuid, "password": password,
            "congestion_control": _q(q, "congestion_control", "bbr"),
            "udp_relay_mode": _q(q, "udp_relay_mode", "native"), "tls": tls}


def parse_anytls(uri: str) -> dict:
    p, host, port, user, q = _common_url(uri)
    if not user:
        raise ValueError("missing password")
    return {"type": "anytls", "server": host, "server_port": port, "password": user,
            "tls": {"enabled": True, "server_name": _q(q, "sni") or host,
                    "insecure": _q(q, "insecure") in ("1", "true") or _q(q, "allowInsecure") in ("1", "true")}}


def parse_wireguard(uri: str) -> dict:
    p, host, port, private_key, q = _common_url(uri.replace("wg://", "wireguard://", 1))
    peer = _q(q, "publickey") or _q(q, "public_key") or _q(q, "peer_public_key")
    addresses = [a.strip() for a in (_q(q, "address") or _q(q, "ip")).split(",") if a.strip()]
    if not private_key or not peer or not addresses:
        raise ValueError("bad wireguard")
    addresses = [a if "/" in a else (a + ("/128" if ":" in a else "/32")) for a in addresses]
    out = {"type": "wireguard", "server": host, "server_port": port, "private_key": private_key,
           "peer_public_key": peer, "local_address": addresses, "mtu": int(_q(q, "mtu", "1280") or 1280)}
    if _q(q, "presharedkey"):
        out["pre_shared_key"] = _q(q, "presharedkey")
    reserved = _q(q, "reserved")
    if reserved:
        out["reserved"] = [int(x) for x in reserved.split(",")]
    return out


def parse_socks(uri: str) -> dict:
    p, host, port, user, q = _common_url(uri.replace("socks5://", "socks://", 1))
    out = {"type": "socks", "server": host, "server_port": port, "version": "5"}
    if user:
        if ":" not in user:
            user = b64decode(user)
        username, _, password = user.partition(":")
        out.update({"username": username, "password": password})
    return out


def parse_uri(uri: str) -> dict | None:
    """Return a sing-box outbound (without tag), or None when unsupported/invalid."""
    try:
        if uri.startswith("anytls://"):
            return parse_anytls(uri)
        if uri.startswith(("wireguard://", "wg://")):
            return parse_wireguard(uri)
        if uri.startswith(("socks://", "socks5://")):
            return parse_socks(uri)
        if uri.startswith("vmess://"):
            return parse_vmess(uri)
        if uri.startswith(("vless://", "trojan://")):
            return parse_vless_trojan(uri)
        if uri.startswith("ss://"):
            return parse_ss(uri)
        if uri.startswith(("hysteria2://", "hy2://")):
            return parse_hysteria2(uri)
        if uri.startswith("tuic://"):
            return parse_tuic(uri)
    except Exception:
        return None
    return None


def dedupe_key(outbound: dict) -> str:
    """Identity of a node = its full connection settings, not just host:port."""
    return json.dumps(outbound, sort_keys=True)


def rename_uri(uri: str, name: str) -> str:
    if uri.startswith("vmess://"):
        d = json.loads(b64decode(uri[len("vmess://"):]))
        d["ps"] = name
        return "vmess://" + base64.b64encode(json.dumps(d, ensure_ascii=False).encode()).decode()
    return uri.split("#", 1)[0] + "#" + quote(name)


def extract_configs(blob: str) -> list[str]:
    """Pull share links out of plain text, a whole-file base64 blob, or base64-encoded lines."""
    found = []
    candidates = [blob]
    if not any(p in blob for p in SUPPORTED_PREFIXES):
        try:
            candidates = [b64decode("".join(blob.split()))]
        except Exception:
            pass
    for text in candidates:
        for raw in text.splitlines():
            line = raw.strip()
            if line.startswith(SUPPORTED_PREFIXES):
                found.append(line)
            elif line and len(line) > 16 and "://" not in line:
                try:
                    decoded = b64decode(line)
                except Exception:
                    continue
                found.extend(l.strip() for l in decoded.splitlines() if l.strip().startswith(SUPPORTED_PREFIXES))
    return found
