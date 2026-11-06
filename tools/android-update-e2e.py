#!/usr/bin/env python3
"""End-to-end test for Android's browser-based update hand-off.

The Android app intentionally opens the signed APK URL in the user's browser.
It does not download/install APKs itself (to avoid REQUEST_INSTALL_PACKAGES and
Play Protect dropper heuristics). This test installs the previous release,
waits for the in-app update notice, taps Update, and verifies that Android
hands the request to the resolved HTTPS browser/chooser instead of expecting
the app version to change automatically.

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
UPDATE_LABELS = {"update", "به‌روزرسانی", "بروزرسانی", "به روزرسانی"}
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
    print(f"installed old version {old_version}; expecting browser hand-off for {new_version}")
    if not old_version or old_version == new_version:
        raise SystemExit("old APK version is missing or already equals the target version")

    browser_package = resolve_https_handler()
    print(f"resolved HTTPS handler: {browser_package or 'system chooser / unresolved'}")
    deadline = time.time() + 15 * 60
    last_launch = 0.0
    update_tapped = False

    while time.time() < deadline:
        nodes = ui_nodes()
        packages = {n.get("package", "") for n in nodes}
        texts = " ".join((n.get("text") or "") for n in nodes).translate(
            str.maketrans("۰۱۲۳۴۵۶۷۸۹", "0123456789")
        )

        if update_tapped:
            foreground = resumed_package()
            if foreground and foreground != PKG:
                normalized = foreground.lower()
                expected = browser_package.lower()
                is_expected = bool(expected and normalized == expected)
                is_browser = any(token in normalized for token in BROWSER_OR_CHOOSER)
                if is_expected or is_browser:
                    shot("3-browser-handoff")
                    print(f"✅ update hand-off opened {foreground}; installed version remains {installed_version()} as expected")
                    return
            # Give the browser/chooser a little time to become the resumed activity.
            time.sleep(2)
            continue

        if PKG in packages:
            sheet = [n for n in nodes if (n.get("text") or "").strip() in SHEET_DISMISS]
            if sheet:
                tap(sheet[0])
                print(f"dismissed first-run sheet: {sheet[0].get('text')!r}")
            elif new_version in texts:
                buttons = [
                    n for n in nodes
                    if n.get("clickable") == "true"
                    and (
                        n.get("resource-id") == "android:id/button1"
                        or (n.get("text") or "").strip().lower() in UPDATE_LABELS
                    )
                ]
                if buttons:
                    shot("1-update-dialog")
                    tap(buttons[0])
                    update_tapped = True
                    print("tapped Update in the app dialog; waiting for HTTPS browser hand-off")
        if not update_tapped and time.time() - last_launch > 60:
            adb("shell", "am", "force-stop", PKG)
            adb("shell", "am", "start", "-W", "-n", ACTIVITY)
            last_launch = time.time()
            print("launched app; waiting for the update notice")
        time.sleep(4)

    shot("fail")
    print("--- foreground activity ---")
    print(adb("shell", "dumpsys", "activity", "activities")[-12000:])
    print("--- app logcat ---")
    print(adb("logcat", "-d", "-t", "300"))
    if not update_tapped:
        raise SystemExit("update notice did not appear; app never offered the target version")
    raise SystemExit(f"Update was tapped but browser hand-off was not observed (foreground={resumed_package()!r})")


if __name__ == "__main__":
    main()
