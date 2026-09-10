#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/upstream.env"

PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
RELEASE_CONFIG="${ANDROID_RELEASE_CONFIG:-aosp_current}"
VARIANT="${BUILD_VARIANT:-userdebug}"
LUNCH_TARGET="${PRODUCT}-${RELEASE_CONFIG}-${VARIANT}"

if [[ ! -d "$AOSP_DIR/build" ]]; then
  echo "ERROR: AOSP tree not found at $AOSP_DIR" >&2
  echo "Run scripts/sync-aosp.sh first." >&2
  exit 2
fi

cd "$AOSP_DIR"
# shellcheck disable=SC1091
source build/envsetup.sh

echo "LUNCH_TARGET = $LUNCH_TARGET"
if ! lunch "$LUNCH_TARGET"; then
  cat >&2 <<EOF
ERROR: product $LUNCH_TARGET is not registered or compatible with the current Android release configuration.
The Android 17 PC BSP/device tree must be installed before ISO compilation.
This script intentionally refuses to fall back to Cuttlefish because the project target is a bootable/installable VM OS.
EOF
  exit 3
fi

if ! m iso_img; then
  cat >&2 <<'EOF'
ERROR: iso_img target failed or is not implemented by the current PC BSP.
A valid release must produce a BIOS/UEFI bootable ISO; a Cuttlefish image is not accepted as a substitute.
EOF
  exit 4
fi

OUT_DIR="${OUT_DIR:-$AOSP_DIR/out/target/product/$PRODUCT}"
find "$OUT_DIR" -maxdepth 2 -type f \( -name '*.iso' -o -name '*.img' \) -print
