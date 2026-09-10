#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AOSP_DIR="${AOSP_DIR:-$HOME/aosp-accessible-android}"
STAGE_DIR="$AOSP_DIR/vendor/accessibledroid/private-gms"

"$ROOT_DIR/scripts/validate-gms-input.sh"

[[ -d "$AOSP_DIR/.repo" ]] || {
  echo "ERROR: AOSP checkout not found at $AOSP_DIR" >&2
  exit 2
}

[[ -f "$GMS_BUNDLE_DIR/payload/gms-product.mk" ]] || {
  echo "ERROR: authorized payload must contain payload/gms-product.mk" >&2
  exit 3
}

case "$STAGE_DIR" in
  "$AOSP_DIR"/vendor/accessibledroid/private-gms) ;;
  *)
    echo "ERROR: unsafe GMS staging path" >&2
    exit 4
    ;;
esac

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -a "$GMS_BUNDLE_DIR/payload/." "$STAGE_DIR/"

echo "GMS_STAGE_DIR = $STAGE_DIR"
echo "GMS_STAGE = READY"
