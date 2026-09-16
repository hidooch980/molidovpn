#!/usr/bin/env python3
"""End-to-end test of the Android in-app updater on the CI emulator.

Installs the PREVIOUS release's APK, opens the app and lets it find the release that was just published,
then walks through what a real user does: "Update" in the app dialog, in-app download, the system
installer's "Install/Update" button. Passes only when the installed versionName becomes the new version.

usage: android-update-e2e.py <old.apk> <new-version>
"""
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = "com.mobin.mobin_vpn"
ACTIVITY = f"{PKG}/com.molido.vpn.MainActivity"
INSTALLER_BUTTONS = re.compile(r"^(install|update|نصب|به‌روزرسانی|بروزرسانی)$", re.I)


def adb(*args, check=False):
    r = subprocess.run(["adb", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"adb {' '.join(args)} failed: {r.stderr}")
    return r.stdout


def installed_version():
    m = re.search(r"versionName=(\S+)", adb("shell", "dumpsys", "package", PKG))
    return m.group(1) if m else None


def shot(name):
    subprocess.run(f"mkdir -p shots && adb exec-out screencap -p > shots/update-{name}.png", shell=True)


def ui_nodes():
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = adb("shell", "cat", "/sdcard/ui.xml")
    start = xml.find("<?xml")
    if start < 0:
        return []
    try:
        return list(ET.fromstring(xml[start:]).iter("node"))
    except ET.ParseError:
        return []


def tap(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "[0,0][0,0]")))
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


def main():
    old_apk, new_version = sys.argv[1], sys.argv[2]
    adb("uninstall", PKG)
    adb("install", "-r", old_apk, check=True)
    old_version = installed_version()
    print(f"installed old version {old_version}, waiting for update to {new_version}")
    if old_version == new_version:
        raise SystemExit("old APK already is the new version")
    # Same as the user tapping "Allow" on the one-time "install unknown apps" screen.
    adb("shell", "appops", "set", PKG, "REQUEST_INSTALL_PACKAGES", "allow")
    adb("shell", "appops", "set", PKG, "ACTIVATE_VPN", "allow")

    deadline = time.time() + 15 * 60
    last_launch = 0.0
    stage = "launch"
    while time.time() < deadline:
        version = installed_version()
        if version == new_version:
            time.sleep(3)
            adb("shell", "am", "start", "-W", "-n", ACTIVITY)
            time.sleep(6)
            shot("4-updated")
            print(f"✅ in-app update worked: {old_version} → {version}")
            return
        nodes = ui_nodes()
        packages = {n.get("package", "") for n in nodes}
        texts = " ".join((n.get("text") or "") for n in nodes).translate(str.maketrans("۰۱۲۳۴۵۶۷۸۹", "0123456789"))
        if any("packageinstaller" in p for p in packages):
            if stage != "installer":
                stage = "installer"
                shot("3-system-installer")
                print("system installer is showing")
            for n in nodes:
                if INSTALLER_BUTTONS.match((n.get("text") or "").strip()) and n.get("clickable") == "true":
                    tap(n)
                    print(f"tapped installer button '{n.get('text')}'")
                    break
        elif not (packages & {PKG, "com.google.android.apps.nexuslauncher", "com.android.launcher3", "com.android.systemui"}) and packages:
            # Any other system dialog in the way (VPN consent, permission prompts): accept it.
            ok = [n for n in nodes if n.get("resource-id") == "android:id/button1"] or                  [n for n in nodes if (n.get("text") or "").strip().upper() in ("OK", "ALLOW", "ALLOW ALL THE TIME")]
            if ok:
                tap(ok[0])
                print(f"accepted system dialog from {sorted(packages)}")
        elif PKG in packages:
            positive = [n for n in nodes if n.get("resource-id") == "android:id/button1"]
            if positive and new_version in texts:
                shot("1-update-dialog")
                tap(positive[0])
                stage = "downloading"
                print("tapped Update in the app dialog")
            elif positive and stage != "downloading":
                tap(positive[0])  # first-run dialogs (consent, notices)
                print(f"dismissed a dialog: {texts[:80]!r}")
            elif stage == "downloading" and "%" in texts:
                shot("2-downloading")
        # Worker caches release info for a few minutes: relaunch until the app sees the new version.
        if stage == "launch" and time.time() - last_launch > 60:
            adb("shell", "am", "force-stop", PKG)
            adb("shell", "am", "start", "-W", "-n", ACTIVITY)
            last_launch = time.time()
            print("launched app, waiting for the update dialog")
        time.sleep(4)

    shot("fail")
    print("--- logcat ---")
    print(adb("logcat", "-d", "-t", "300"))
    raise SystemExit(f"❌ still on {installed_version()} after 15 min, expected {new_version}")


if __name__ == "__main__":
    main()
