#!/usr/bin/env python3
"""End-to-end test for the Android in-app update flow.

Installs the previous signed APK, waits for the current home-screen update
banner, follows its confirmation, and verifies the Android package-installer
handoff and resulting installed version. Older releases that still use a
browser hand-off remain supported.

usage: android-update-e2e.py <old.apk> <new-version>
"""

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = "com.mobin.mobin_vpn"
ACTIVITY = f"{PKG}/com.molido.vpn.MainActivity"
SHEET_DISMISS = {"ارسال نشود", "Don't send", "Do not send"}
UPDATE_ACTION_LABELS = ("download update", "install update", "update available", "دانلود بروزرسانی", "دریافت بروزرسانی", "نصب بروزرسانی", "به‌روزرسانی")
UPDATE_CONFIRM_LABELS = {"update", "install", "download", "به‌روزرسانی", "بروزرسانی", "به روزرسانی", "نصب", "دانلود"}
INSTALL_CONFIRM_LABELS = {"install", "update", "نصب", "به‌روزرسانی", "بروزرسانی"}
INSTALLER_OR_SETTINGS = ("packageinstaller", "package installer", "permissioncontroller", "installer", "com.android.settings")
BROWSER_OR_CHOOSER = (
    "chrome", "browser", "firefox", "intentresolver", "resolver",
    "chooser", "opera", "brave", "edge",
)


def adb(*args, check=False):
    r = subprocess.run(["adb", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"adb {' '.join(args)} failed: {r.stderr}")
    return r.stdout


def installed_version():
    m = re.search(r"versionName=(\S+)", adb("shell", "dumpsys", "package", PKG))
    return m.group(1) if m else None


def shot(name):
    subprocess.run("mkdir -p shots && adb exec-out screencap -p > shots/update-" + name + ".png", shell=True, check=False)


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
    values = list(map(int, re.findall(r"\d+", node.get("bounds", "[0,0][0,0]"))))
    if len(values) != 4:
        return
    x1, y1, x2, y2 = values
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


def resumed_package():
    dump = adb("shell", "dumpsys", "activity", "activities")
    patterns = (
        r"mResumedActivity:.*?\s([\w.]+)/[\w.$]+",
        r"topResumedActivity=ActivityRecord\{[^}]*\s([\w.]+)/[\w.$]+",
    )
    for pattern in patterns:
        match = re.search(pattern, dump)
        if match:
            return match.group(1)
    return ""


def resolve_https_handler():
    out = adb(
        "shell", "cmd", "package", "resolve-activity", "--brief",
        "-a", "android.intent.action.VIEW", "-d",
        "https://github.com/hidooch980/molidovpn/releases/latest",
    )
    for line in reversed(out.splitlines()):
        match = re.search(r"([\w.]+)/[\w.$]+", line.strip())
        if match:
            return match.group(1)
    return ""


def main():
    old_apk, new_version = sys.argv[1], sys.argv[2]
    adb("uninstall", PKG)
    adb("install", "-r", old_apk, check=True)
    old_version = installed_version()
    print(f"installed old version {old_version}; expecting update flow for {new_version}")
    if not old_version or old_version == new_version:
        raise SystemExit("old APK version is missing or already equals the target version")

    # The current Android app uses a tappable version card, then in-app download
    # and the Android package installer. Older builds may use a browser hand-off.
    # Grant the install app-op in the disposable emulator so the test can reach
    # the installer without a manual Settings detour.
    adb("shell", "appops", "set", PKG, "REQUEST_INSTALL_PACKAGES", "allow")

    deadline = time.time() + 15 * 60
    last_launch = 0.0
    banner_tapped = False
    confirm_tapped = False
    installer_confirmed = False

    while time.time() < deadline:
        nodes = ui_nodes()
        packages = {n.get("package", "") for n in nodes}
        texts = " ".join((n.get("text") or "") for n in nodes).translate(
            str.maketrans("۰۱۲۳۴۵۶۷۸۹", "0123456789")
        )
        lower_texts = texts.lower()

        if installed_version() == new_version:
            shot("4-updated-version")
            print(f"✅ installed version upgraded to {new_version}")
            return

        if confirm_tapped:
            foreground = resumed_package()
            normalized = foreground.lower()
            is_browser = any(token in normalized for token in BROWSER_OR_CHOOSER)
            is_installer = any(token in normalized for token in INSTALLER_OR_SETTINGS)
            if is_browser:
                shot("3-browser-handoff")
                print(f"✅ legacy browser hand-off opened {foreground}")
                return
            if is_installer:
                # Confirm the Android system installer when its confirmation button appears.
                install_buttons = [
                    n for n in nodes
                    if n.get("clickable") == "true"
                    and (n.get("text") or "").strip().lower() in INSTALL_CONFIRM_LABELS
                ]
                if install_buttons and not installer_confirmed:
                    shot("3-installer-confirm")
                    tap(install_buttons[0])
                    installer_confirmed = True
                    print(f"confirmed Android installer in {foreground}")
                elif installer_confirmed:
                    time.sleep(2)
                    continue
            time.sleep(2)
            continue

        if PKG in packages:
            sheet = [n for n in nodes if (n.get("text") or "").strip() in SHEET_DISMISS]
            if sheet:
                tap(sheet[0])
                print(f"dismissed first-run sheet: {sheet[0].get('text')!r}")
            elif new_version in texts and not banner_tapped:
                # Current app exposes a tappable version card; the version text is its label.
                version_nodes = [
                    n for n in nodes
                    if new_version in ((n.get("text") or "") + " " + (n.get("content-desc") or ""))
                ]
                clickable = [
                    n for n in nodes
                    if n.get("clickable") == "true"
                    and (
                        new_version in ((n.get("text") or "") + " " + (n.get("content-desc") or ""))
                        or any(label in (n.get("text") or "").strip().lower() for label in UPDATE_ACTION_LABELS)
                    )
                ]
                if not clickable and version_nodes:
                    # Text may be a non-clickable child of the tappable AppCard.
                    def node_bounds(node):
                        values = list(map(int, re.findall(r"\\d+", node.get("bounds", ""))))
                        return values if len(values) == 4 else None
                    target = node_bounds(version_nodes[0])
                    if target:
                        cx, cy = (target[0] + target[2]) // 2, (target[1] + target[3]) // 2
                        parents = []
                        for node in nodes:
                            b = node_bounds(node)
                            if node.get("clickable") == "true" and b and b[0] <= cx <= b[2] and b[1] <= cy <= b[3]:
                                parents.append(((b[2] - b[0]) * (b[3] - b[1]), node))
                        if parents:
                            clickable = [min(parents, key=lambda item: item[0])[1]]
                if clickable:
                    shot("1-update-banner")
                    tap(clickable[0])
                    banner_tapped = True
                    confirm_tapped = True  # tapping the card starts the download directly
                    print("tapped update card; waiting for download and Android installer")
            if not confirm_tapped and time.time() - last_launch > 60:
                adb("shell", "am", "force-stop", PKG)
                adb("shell", "am", "start", "-W", "-n", ACTIVITY)
                last_launch = time.time()
                print("launched app; waiting for update banner")
        time.sleep(4)

    shot("fail")
    print(f"--- installed version: {installed_version()} ---")
    print(f"--- foreground package: {resumed_package()} ---")
    print("--- foreground activity ---")
    print(adb("shell", "dumpsys", "activity", "activities")[-12000:])
    print("--- app logcat ---")
    print(adb("logcat", "-d", "-t", "500"))
    if not banner_tapped:
        raise SystemExit("update banner did not appear or its action was not clickable")
    if not confirm_tapped:
        raise SystemExit("update card action was not triggered")
    if installed_version() != new_version:
        raise SystemExit("installer handoff was observed, but the target version was not installed")


if __name__ == "__main__":
    main()
