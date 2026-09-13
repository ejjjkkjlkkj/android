#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GMS_DIR="${GMS_BUNDLE_DIR:-}"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

[[ -n "$GMS_DIR" ]] || fail "GMS_BUNDLE_DIR is not set."
[[ -d "$GMS_DIR" ]] || fail "GMS bundle directory does not exist: $GMS_DIR"

GMS_DIR="$(cd "$GMS_DIR" && pwd -P)"
ROOT_REAL="$(cd "$ROOT_DIR" && pwd -P)"

case "$GMS_DIR/" in
  "$ROOT_REAL"/*)
    fail "GMS_BUNDLE_DIR must live outside the Git repository. Keep proprietary inputs private."
    ;;
esac

[[ -f "$GMS_DIR/LICENSE_ACCEPTED" ]] || fail "Missing local LICENSE_ACCEPTED marker."
[[ -f "$GMS_DIR/gms-bundle.manifest" ]] || fail "Missing gms-bundle.manifest."
[[ -d "$GMS_DIR/payload" ]] || fail "Missing payload directory."
[[ -s "$GMS_DIR/gms-bundle.manifest" ]] || fail "gms-bundle.manifest is empty."

if find "$GMS_DIR/payload" -type l -print -quit | grep -q .; then
  fail "Symlinks are not accepted inside the GMS payload."
fi

(
  cd "$GMS_DIR"
  sha256sum --check --strict gms-bundle.manifest
) || fail "GMS payload checksum verification failed."

manifest_files="$(awk '{sub(/^\*/, "", $2); print $2}' "$GMS_DIR/gms-bundle.manifest" | sort -u)"
payload_files="$(cd "$GMS_DIR" && find payload -type f -print | sed 's#^./##' | sort -u)"

[[ "$manifest_files" == "$payload_files" ]] || fail "Manifest must cover every payload file exactly once."

echo "GMS_INPUT = VERIFIED"
echo "GMS_BUNDLE_DIR = $GMS_DIR"
echo "FILES = $(printf '%s\n' "$payload_files" | sed '/^$/d' | wc -l)"
