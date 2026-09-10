#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/upstream.env"

AOSP_DIR="${AOSP_DIR:-$HOME/aosp-accessible-android}"
PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
VARIANT="${BUILD_VARIANT:-userdebug}"

if [[ ! -d "$AOSP_DIR/build" ]]; then
  echo "ERROR: AOSP tree not found at $AOSP_DIR" >&2
  echo "Run scripts/sync-aosp.sh first." >&2
  exit 2
fi

cd "$AOSP_DIR"
# shellcheck disable=SC1091
source build/envsetup.sh

if ! lunch "${PRODUCT}-${VARIANT}"; then
  cat >&2 <<EOF
ERROR: product ${PRODUCT}-${VARIANT} is not registered yet.
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
