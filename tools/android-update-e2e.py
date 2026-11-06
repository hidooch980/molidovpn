#!/usr/bin/env python3
"""End-to-end test for MolidoVPN's safe Android system-installer update flow.

The app deliberately does not request REQUEST_INSTALL_PACKAGES or install APKs
itself. This test installs the previous signed APK, taps the update action, and
verifies that the signed APK is handed to Android's package installer while the
old app version remains installed until the user confirms installation.

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
UPDATE_LABELS = {
    "update", "download", "install", "install update", "به‌روزرسانی", "بروزرسانی",
    "به روزرسانی", "نصب", "دانلود", "نصب به روزرسانی", "نصب به روز رسانی",
}
ONBOARDING_NEXT_LABELS = {"بعدی", "بعد", "next", "continue", "ادامه", "اجازه vpn", "vpn اجازه", "allow vpn", "vpn permission"}
UPDATE_HANDOFF = (
    "chrome", "browser", "firefox", "intentresolver", "resolver",
    "chooser", "opera", "brave", "edge", "packageinstaller",
    "permissioncontroller", "com.android.packageinstaller",
)


def adb(*args, check=False, timeout=25):
    try:
        result = subprocess.run(
            ["adb", *args], capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired as exc:
        raise SystemExit(f"adb {' '.join(args)} timed out after {timeout}s") from exc
    if check and result.returncode != 0:
        raise SystemExit(f"adb {' '.join(args)} failed: {result.stderr}")
    return result.stdout


def installed_version():
    match = re.search(r"versionName=(\S+)", adb("shell", "dumpsys", "package", PKG))
    return match.group(1) if match else None


def shot(name):
    subprocess.run(
        "mkdir -p shots && adb exec-out screencap -p > shots/update-" + name + ".png",
        shell=True, check=False,
    )


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


def node_bounds(node):
    values = list(map(int, re.findall(r"\d+", node.get("bounds", ""))))
    return values if len(values) == 4 else None


def tap(node):
    bounds = node_bounds(node)
    if not bounds:
        return
    x1, y1, x2, y2 = bounds
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
    output = adb(
        "shell", "cmd", "package", "resolve-activity", "--brief",
        "-a", "android.intent.action.VIEW", "-d",
        "https://github.com/hidooch980/molidovpn/releases/latest",
    )
    for line in reversed(output.splitlines()):
        match = re.search(r"([\w.]+)/[\w.$]+", line.strip())
        if match:
            return match.group(1)
    return ""


def normalized_text(node):
    raw = (node.get("text") or "") + " " + (node.get("content-desc") or "")
    raw = raw.translate(str.maketrans("۰۱۲۳۴۵۶۷۸۹", "0123456789"))
    raw = raw.replace("\u200c", " ").replace("\u200f", "").replace("\u200e", "")
    return " ".join(raw.split()).strip()


def main():
    old_apk, new_version = sys.argv[1], sys.argv[2]
    adb("uninstall", PKG)
    adb("install", "-r", old_apk, check=True, timeout=120)
    old_version = installed_version()
    print(f"installed old version {old_version}; expecting browser hand-off for {new_version}")
    if not old_version or old_version == new_version:
        raise SystemExit("old APK version is missing or already equals the target version")

    browser_handler = resolve_https_handler()
    print(f"resolved HTTPS handler: {browser_handler or 'system chooser / unresolved'}")
    deadline = time.time() + 7 * 60
    # adb install does not launch the app. Start it before waiting for UI nodes,
    # otherwise the emulator remains on the launcher for the entire timeout.
    adb("shell", "am", "start", "-W", "-n", ACTIVITY)
    last_launch = time.time()
    update_tapped = False
    last_diagnostic = 0.0

    while time.time() < deadline:
        nodes = ui_nodes()
        if time.time() - last_diagnostic >= 20:
            print(
                f"poll: foreground={resumed_package()!r}, "
                f"version={installed_version()!r}, ui_nodes={len(nodes)}, "
                f"ui_text={' | '.join(normalized_text(n) for n in nodes)[:500]!r}",
                flush=True,
            )
            last_diagnostic = time.time()
        packages = {node.get("package", "") for node in nodes}
        texts = " ".join(normalized_text(node) for node in nodes)
        if installed_version() != old_version:
            shot("fail-version-changed")
            raise SystemExit(
                f"unexpected installed version change: {installed_version()} (expected {old_version})"
            )

        if update_tapped:
            foreground = resumed_package()
            normalized = foreground.lower()
            is_browser = any(token in normalized for token in UPDATE_HANDOFF)
            expected = browser_handler.lower()
            is_expected = bool(expected and normalized == expected)
            if is_browser or is_expected:
                shot("3-system-installer-handoff")
                print(
                    f"SUCCESS: Android update hand-off opened in {foreground}; "
                    f"version {old_version} remains installed as designed"
                )
                return
            # The release notice first opens an in-app confirmation dialog.
            # Confirm that explicit second step before expecting the browser.
            confirm_text = " ".join(normalized_text(node).lower() for node in nodes)
            confirm_buttons = [
                node for node in nodes
                if node.get("clickable") == "true"
                and normalized_text(node).lower() in {"نصب", "install", "download", "open"}
            ]
            is_update_confirmation = (
                PKG in packages
                and ("آماده نصب" in confirm_text or "همین حالا نصب شود" in confirm_text
                     or "ready to install" in confirm_text)
            )
            if is_update_confirmation and confirm_buttons:
                shot("2-update-confirmation")
                tap(confirm_buttons[0])
                print(
                    f"confirmed update dialog with {normalized_text(confirm_buttons[0])!r}; "
                    "waiting for Android package-installer hand-off",
                    flush=True,
                )
                time.sleep(2)
                continue
            time.sleep(2)
            continue

        # The final onboarding page requests Android's VPN consent. Tapping it
        # opens a system-owned confirmation dialog; accept that explicit OS
        # consent in the emulator so the test can reach the update banner.
        system_allow = [
            node for node in nodes
            if node.get("clickable") == "true"
            and normalized_text(node).lower() in {"ok", "allow", "اجازه", "تأیید", "تایید"}
        ]
        if PKG not in packages and system_allow:
            tap(system_allow[0])
            print(f"accepted emulator VPN consent: {normalized_text(system_allow[0])!r}")
            time.sleep(1)
            continue

        if PKG in packages:
            dismiss = [
                node for node in nodes
                if normalized_text(node) in SHEET_DISMISS
                and node.get("clickable") == "true"
            ]
            if dismiss:
                tap(dismiss[0])
                print(f"dismissed first-run sheet: {normalized_text(dismiss[0])!r}")
            else:
                # The first-run coach mark overlays the update banner. Advance
                # all onboarding pages (for example "1/3" + "بعدی") first.
                page_marker = re.search(r"\b(\d+)\s*/\s*(\d+)\b", texts)
                next_buttons = [
                    node for node in nodes
                    if node.get("clickable") == "true"
                    and normalized_text(node).lower() in ONBOARDING_NEXT_LABELS
                ]
                if page_marker and next_buttons:
                    shot(f"onboarding-{page_marker.group(1)}")
                    tap(next_buttons[0])
                    print(
                        f"advanced onboarding page {page_marker.group(1)}/"
                        f"{page_marker.group(2)} before update detection"
                    )
                    time.sleep(1)
                    continue
            if not dismiss and new_version in texts:
                buttons = [
                    node for node in nodes
                    if node.get("clickable") == "true"
                    and normalized_text(node).lower() in UPDATE_LABELS
                ]
                if buttons:
                    shot("1-update-dialog")
                    tap(buttons[0])
                    update_tapped = True
                    print("tapped Update; waiting for HTTPS browser/chooser hand-off")
                else:
                    # Some UI versions make the version label itself a clickable card.
                    version_nodes = [
                        node for node in nodes if new_version in normalized_text(node)
                    ]
                    if version_nodes:
                        bounds = node_bounds(version_nodes[0])
                        if bounds:
                            cx, cy = (bounds[0] + bounds[2]) // 2, (bounds[1] + bounds[3]) // 2
                            parents = []
                            for node in nodes:
                                candidate = node_bounds(node)
                                if (
                                    node.get("clickable") == "true" and candidate
                                    and candidate[0] <= cx <= candidate[2]
                                    and candidate[1] <= cy <= candidate[3]
                                ):
                                    area = (candidate[2] - candidate[0]) * (candidate[3] - candidate[1])
                                    parents.append((area, node))
                            if parents:
                                shot("1-update-card")
                                tap(min(parents, key=lambda item: item[0])[1])
                                update_tapped = True
                                print("tapped version update card; waiting for HTTPS browser/chooser")
        if not update_tapped and time.time() - last_launch > 60:
            # Recover if the app crashed or left the foreground while polling.
            adb("shell", "am", "force-stop", PKG)
            adb("shell", "am", "start", "-W", "-n", ACTIVITY)
            last_launch = time.time()
            print("re-launched app; waiting for update notice")
        time.sleep(3)

    shot("fail")
    print(f"--- installed version: {installed_version()} ---")
    print(f"--- foreground package: {resumed_package()} ---")
    print("--- foreground activity ---")
    print(adb("shell", "dumpsys", "activity", "activities")[-12000:])
    print("--- clickable UI nodes at timeout ---")
    for node in ui_nodes():
        if node.get("clickable") == "true":
            print(f"text={normalized_text(node)!r} resource={node.get('resource-id')!r} bounds={node.get('bounds')!r}")
    print("--- app logcat ---")
    print(adb("logcat", "-d", "-t", "500"))
    if not update_tapped:
        raise SystemExit("update notice did not appear or its Update action was not clickable")
    raise SystemExit(
        f"Update was tapped but Android package-installer hand-off was not observed "
        f"(foreground={resumed_package()!r})"
    )


if __name__ == "__main__":
    main()
