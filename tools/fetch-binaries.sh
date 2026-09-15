#!/usr/bin/env bash
# Downloads the prebuilt Psiphon AAR and the Tor / lyrebird / Xray executables into the app tree.
# Source: our own release "binaries-2" (a mirror of mbm110/MSN-GUARD's files), verified by SHA-256.
# Falls back to the upstream repository only if our release is unreachable.
# sing-box (hysteria2 / tuic / anytls) comes straight from SagerNet's release, pinned by SHA-256.
set -euo pipefail

TAG="${BINARIES_TAG:-binaries-2}"
OURS="https://github.com/hidooch980/molidovpn-android/releases/download/$TAG"
UPSTREAM="https://github.com/mbm110/MSN-GUARD/raw/master/app"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"

SINGBOX_VERSION="1.12.25"
SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION"

get() { # name, upstream path
  curl -fsSL --retry 3 -o "$WORK/$1" "$OURS/$1" || {
    echo "mirror missing $1, using upstream"
    curl -fsSL --retry 3 -o "$WORK/$1" "$UPSTREAM/$2"
  }
}

singbox_arch() { # abi -> release arch
  case "$1" in
    arm64-v8a) echo arm64 ;;
    armeabi-v7a) echo arm ;;
  esac
}

singbox_sha() { # abi -> sha256 of sing-box-$SINGBOX_VERSION-android-<arch>.tar.gz
  case "$1" in
    arm64-v8a) echo b9acee7ba78ccb761ba87e5caf6c6db8eaa64bcb746fcef2f5616089efaf4e19 ;;
    armeabi-v7a) echo 8a49c92f05d26d44879072cdbeddab95e54e1b9764911301018a81f34d197ebe ;;
  esac
}

curl -fsSL --retry 3 -o "$WORK/SHA256SUMS.txt" "$OURS/SHA256SUMS.txt"
get psiphontunnel-2.0.39.aar libs/psiphontunnel-2.0.39.aar
for abi in arm64-v8a armeabi-v7a; do
  for lib in libtor.so libobfs4proxy.so libxray.so; do
    get "${abi}__${lib}" "src/main/jniLibs/$abi/$lib"
  done
done

(cd "$WORK" && sed 's/ \*/  /' SHA256SUMS.txt | sha256sum -c -)

for abi in arm64-v8a armeabi-v7a; do
  name="sing-box-$SINGBOX_VERSION-android-$(singbox_arch "$abi")"
  curl -fsSL --retry 3 -o "$WORK/$name.tar.gz" "$SINGBOX_URL/$name.tar.gz"
  (cd "$WORK" && echo "$(singbox_sha "$abi")  $name.tar.gz" | sha256sum -c -)
  tar -xzf "$WORK/$name.tar.gz" -C "$WORK"
done

mkdir -p "$ROOT/app/libs"
cp "$WORK/psiphontunnel-2.0.39.aar" "$ROOT/app/libs/"
for abi in arm64-v8a armeabi-v7a; do
  mkdir -p "$ROOT/app/src/main/jniLibs/$abi"
  for lib in libtor.so libobfs4proxy.so libxray.so; do
    cp "$WORK/${abi}__${lib}" "$ROOT/app/src/main/jniLibs/$abi/$lib"
  done
  cp "$WORK/sing-box-$SINGBOX_VERSION-android-$(singbox_arch "$abi")/sing-box" \
    "$ROOT/app/src/main/jniLibs/$abi/libsingbox.so"
done
echo "binaries ready (checksums verified)"
