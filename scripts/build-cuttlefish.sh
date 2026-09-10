#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/upstream.env"

AOSP_DIR="${AOSP_DIR:-$ROOT/.work/aosp}"
TARGET="${TARGET:-$AOSP_PRIMARY_TARGET}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

if [[ ! -f "$AOSP_DIR/build/envsetup.sh" ]]; then
  echo "ERROR: AOSP source tree not found at $AOSP_DIR. Run scripts/sync-aosp.sh first." >&2
  exit 2
fi

cd "$AOSP_DIR"
# shellcheck disable=SC1091
source build/envsetup.sh
lunch "$TARGET"
m -j"$BUILD_JOBS"

PRODUCT_OUT="$(get_build_var PRODUCT_OUT)"
HOST_OUT="$(get_build_var HOST_OUT)"

printf '%s\n' \
  "BUILD=PASS" \
  "TARGET=$TARGET" \
  "PRODUCT_OUT=$PRODUCT_OUT" \
  "HOST_OUT=$HOST_OUT"

cat > "$ROOT/config/last-build.env" <<EOF
TARGET=$TARGET
PRODUCT_OUT=$PRODUCT_OUT
HOST_OUT=$HOST_OUT
EOF
