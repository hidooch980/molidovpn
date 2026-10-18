#!/usr/bin/env bash
# Copies a release to an S3-compatible public bucket (ArvanCloud Object Storage, Cloudflare R2, ...)
# so the app's updater can fall back to it (remote/resilience.json → mirrors.update).
#
#   tools/mirror-upload.sh <tag> <dist-dir> [resilience.json]
#
# Needs MIRROR_S3_ENDPOINT, MIRROR_S3_BUCKET, MIRROR_S3_ACCESS_KEY, MIRROR_S3_SECRET_KEY and
# MIRROR_PUBLIC_URL. Missing any of them = nothing to do, exit 0 (the release never depends on it).
# Layout written:  latest.json, MolidoVPN-android-*.apk, remote/resilience.json, sub.txt
set -euo pipefail
TAG="$1"; DIST="$2"; RES="${3:-}"
for v in MIRROR_S3_ENDPOINT MIRROR_S3_BUCKET MIRROR_S3_ACCESS_KEY MIRROR_S3_SECRET_KEY MIRROR_PUBLIC_URL; do
  if [ -z "${!v:-}" ]; then echo "mirror: $v not set — skipped"; exit 0; fi
done
export AWS_ACCESS_KEY_ID="$MIRROR_S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$MIRROR_S3_SECRET_KEY" AWS_DEFAULT_REGION="${MIRROR_S3_REGION:-auto}"
PUB="${MIRROR_PUBLIC_URL%/}"
S3() { aws --endpoint-url "$MIRROR_S3_ENDPOINT" s3 "$@"; }
ACL=()
[ "${MIRROR_S3_ACL:-public-read}" = "none" ] || ACL=(--acl "${MIRROR_S3_ACL:-public-read}")

shopt -s nullglob
apks=("$DIST"/MolidoVPN-android-*.apk)
[ ${#apks[@]} -gt 0 ] || { echo "mirror: no APKs in $DIST"; exit 0; }
for f in "${apks[@]}"; do
  S3 cp "$f" "s3://$MIRROR_S3_BUCKET/$(basename "$f")" --content-type application/vnd.android.package-archive "${ACL[@]}"
done
# latest.json last, so a phone never sees a version whose files are not there yet.
python3 - "$TAG" "$PUB" "${apks[@]}" > "$DIST/mirror-latest.json" <<'PY'
import hashlib, json, os, sys
tag, pub, files = sys.argv[1], sys.argv[2], sys.argv[3:]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
    return h.hexdigest()
assets = []
for p in files:
    n, d = os.path.basename(p), sha(p)
    assets.append({"name": n, "size": os.path.getsize(p), "sha256": d, "digest": "sha256:" + d,
                   "browser_download_url": f"{pub}/{n}"})
print(json.dumps({"tag_name": tag, "assets": assets}, indent=1))
PY
[ -n "$RES" ] && [ -f "$RES" ] && S3 cp "$RES" "s3://$MIRROR_S3_BUCKET/remote/resilience.json" --content-type application/json "${ACL[@]}"
if curl -fsSL --max-time 60 https://raw.githubusercontent.com/hidooch980/vpn-sub/sub/sub.txt -o "$DIST/mirror-sub.txt"; then
  S3 cp "$DIST/mirror-sub.txt" "s3://$MIRROR_S3_BUCKET/sub.txt" --content-type "text/plain; charset=utf-8" --cache-control max-age=600 "${ACL[@]}"
fi
S3 cp "$DIST/mirror-latest.json" "s3://$MIRROR_S3_BUCKET/latest.json" --content-type application/json --cache-control max-age=300 "${ACL[@]}"
rm -f "$DIST/mirror-latest.json" "$DIST/mirror-sub.txt"
echo "mirror: $TAG uploaded to $PUB"
