import base64
import json
import os
import sys
import unittest
from urllib.parse import unquote

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import countries
from parsers import dedupe_key, extract_configs, parse_uri, rename_uri

UUID = "11111111-2222-3333-4444-555555555555"
VLESS_REALITY = (f"vless://{UUID}@1.2.3.4:443?security=reality&sni=www.google.com&fp=chrome"
                 f"&pbk=abcDEF123&sid=ab12&flow=xtls-rprx-vision&type=tcp#old")
VLESS_WS = f"vless://{UUID}@104.16.1.1:443?security=tls&type=ws&path=%2Fws%3Fed%3D2048&host=a.example.com#x"
VMESS = "vmess://" + base64.b64encode(json.dumps({
    "v": "2", "ps": "old", "add": "example.com", "port": "8443", "id": UUID, "aid": "0",
    "net": "grpc", "path": "svc", "tls": "tls", "sni": "example.com"}).encode()).decode()
TROJAN = "trojan://p%40ss@t.example.com:443?sni=t.example.com#t"
SS_SIP002 = "ss://" + base64.urlsafe_b64encode(b"aes-256-gcm:secret").decode().rstrip("=") + "@5.6.7.8:8388#s"
SS_LEGACY = "ss://" + base64.b64encode(b"chacha20-ietf-poly1305:pw@9.9.9.9:1234").decode() + "#l"
HY2 = "hy2://pass@h.example.com:8443?sni=h.example.com&insecure=1&obfs=salamander&obfs-password=o#h"
TUIC = f"tuic://{UUID}:pw@q.example.com:443?congestion_control=bbr&alpn=h3&sni=q.example.com#q"


class ParserTests(unittest.TestCase):
    def test_vless_reality(self):
        ob = parse_uri(VLESS_REALITY)
        self.assertEqual(ob["tls"]["reality"]["public_key"], "abcDEF123")
        self.assertEqual(ob["flow"], "xtls-rprx-vision")

    def test_vless_ws_early_data(self):
        t = parse_uri(VLESS_WS)["transport"]
        self.assertEqual((t["path"], t["max_early_data"], t["headers"]["Host"]), ("/ws", 2048, "a.example.com"))

    def test_vmess_grpc(self):
        ob = parse_uri(VMESS)
        self.assertEqual((ob["server_port"], ob["transport"]["service_name"]), (8443, "svc"))

    def test_trojan_ss_hy2_tuic(self):
        self.assertEqual(parse_uri(TROJAN)["password"], "p@ss")
        self.assertEqual(parse_uri(SS_SIP002)["password"], "secret")
        self.assertEqual(parse_uri(SS_LEGACY)["server"], "9.9.9.9")
        self.assertEqual(parse_uri(HY2)["obfs"]["password"], "o")
        self.assertEqual(parse_uri(TUIC)["password"], "pw")

    def test_anytls_wireguard_socks(self):
        a = parse_uri("anytls://pw@a.example.com:443?sni=s.example.com#a")
        self.assertEqual((a["type"], a["password"], a["tls"]["server_name"]), ("anytls", "pw", "s.example.com"))
        w = parse_uri("wireguard://cHJpdmF0ZQ%3D%3D@8.8.4.4:51820?publickey=cGVlcg%3D%3D&address=10.0.0.2,fd00::2&reserved=1,2,3#w")
        self.assertEqual((w["private_key"], w["peer_public_key"]), ("cHJpdmF0ZQ==", "cGVlcg=="))
        self.assertEqual((w["local_address"], w["reserved"]), (["10.0.0.2/32", "fd00::2/128"], [1, 2, 3]))
        s = parse_uri("socks://" + base64.b64encode(b"u:p").decode() + "@1.1.1.1:1080#s")
        self.assertEqual((s["username"], s["password"]), ("u", "p"))
        self.assertEqual(parse_uri("socks5://2.2.2.2:1080")["server_port"], 1080)
        self.assertIsNone(parse_uri("wireguard://key@h.com:51820?address=10.0.0.2"))

    def test_invalid_rejected(self):
        for bad in ("vless://@1.2.3.4:443", "vmess://notbase64", f"vless://{UUID}@h:443?type=xhttp",
                    f"vless://{UUID}@h:443?security=reality", "trojan://x@h:99999"):
            self.assertIsNone(parse_uri(bad), bad)

    def test_dedupe_keeps_same_ip_different_path(self):
        a = parse_uri(VLESS_WS)
        b = parse_uri(VLESS_WS.replace("%2Fws", "%2Fother"))
        self.assertNotEqual(dedupe_key(a), dedupe_key(b))
        self.assertEqual(dedupe_key(a), dedupe_key(parse_uri(VLESS_WS.replace("#x", "#y"))))

    def test_rename(self):
        name = "🇩🇪 Germany 01 | vless"
        self.assertEqual(unquote(rename_uri(VLESS_REALITY, name).split("#")[1]), name)
        vm = rename_uri(VMESS, name)
        self.assertEqual(json.loads(base64.b64decode(vm[8:]))["ps"], name)
        self.assertEqual(parse_uri(vm), parse_uri(VMESS))

    def test_extract_formats(self):
        plain = f"{VLESS_REALITY}\n{TROJAN}\n"
        self.assertEqual(len(extract_configs(plain)), 2)
        self.assertEqual(len(extract_configs(base64.b64encode(plain.encode()).decode())), 2)

    def test_countries(self):
        self.assertEqual(countries.flag("DE"), "🇩🇪")
        self.assertEqual(countries.name(""), "Unknown")


if __name__ == "__main__":
    unittest.main()
