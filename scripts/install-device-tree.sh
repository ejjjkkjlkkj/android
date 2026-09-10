#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"

[[ -d "$AOSP_DIR/.repo" ]] || {
  echo "ERROR: AOSP checkout not found at $AOSP_DIR" >&2
  exit 2
}

command -v rsync >/dev/null 2>&1 || {
  echo "ERROR: rsync is required" >&2
  exit 3
}

mkdir -p "$AOSP_DIR/device/accessibledroid"
rsync -a --delete "$ROOT_DIR/device/accessibledroid/" "$AOSP_DIR/device/accessibledroid/"

if [[ -d "$ROOT_DIR/vendor/accessibledroid" ]]; then
  mkdir -p "$AOSP_DIR/vendor/accessibledroid"
  rsync -a --delete \
    --exclude private-gms \
    --exclude 'generated-apps/*.apk' \
    --exclude 'generated-apps/*.generated' \
    "$ROOT_DIR/vendor/accessibledroid/" \
    "$AOSP_DIR/vendor/accessibledroid/"
fi

echo "ACCESSIBLE_DEVICE_TREE = INSTALLED"
echo "AOSP_DIR = $AOSP_DIR"
