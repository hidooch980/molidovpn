#!/usr/bin/env bash
# Downloads the prebuilt Psiphon AAR and the Tor / lyrebird / Xray executables into the app tree.
# Source: our own release "binaries-1" (a mirror of mbm110/MSN-GUARD's files), verified by SHA-256.
# Falls back to the upstream repository only if our release is unreachable.
set -euo pipefail

TAG="${BINARIES_TAG:-binaries-1}"
OURS="https://github.com/hidooch980/molidovpn-android/releases/download/$TAG"
UPSTREAM="https://github.com/mbm110/MSN-GUARD/raw/master/app"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"

get() { # name, upstream path
  curl -fsSL --retry 3 -o "$WORK/$1" "$OURS/$1" || {
    echo "mirror missing $1, using upstream"
    curl -fsSL --retry 3 -o "$WORK/$1" "$UPSTREAM/$2"
  }
}

curl -fsSL --retry 3 -o "$WORK/SHA256SUMS.txt" "$OURS/SHA256SUMS.txt"
get psiphontunnel-2.0.39.aar libs/psiphontunnel-2.0.39.aar
for abi in arm64-v8a armeabi-v7a; do
  for lib in libtor.so libobfs4proxy.so libxray.so; do
    get "${abi}__${lib}" "src/main/jniLibs/$abi/$lib"
  done
done

(cd "$WORK" && sed 's/ \*/  /' SHA256SUMS.txt | sha256sum -c -)

mkdir -p "$ROOT/app/libs"
cp "$WORK/psiphontunnel-2.0.39.aar" "$ROOT/app/libs/"
for abi in arm64-v8a armeabi-v7a; do
  mkdir -p "$ROOT/app/src/main/jniLibs/$abi"
  for lib in libtor.so libobfs4proxy.so libxray.so; do
    cp "$WORK/${abi}__${lib}" "$ROOT/app/src/main/jniLibs/$abi/$lib"
  done
done
echo "binaries ready (checksums verified)"
