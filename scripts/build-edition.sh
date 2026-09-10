#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/editions.env"

EDITION="${1:-$DEFAULT_EDITION}"
GMS_STAGE_DIR="$AOSP_DIR/vendor/accessibledroid/private-gms"
GMS_STAGED=0

cleanup() {
  if [[ "$GMS_STAGED" == "1" && -d "$GMS_STAGE_DIR" ]]; then
    rm -rf "$GMS_STAGE_DIR"
    echo "GMS_STAGE = CLEANED"
  fi
}
trap cleanup EXIT INT TERM

case "$EDITION" in
  "$AOSP_EDITION")
    export ACCESSIBLE_ANDROID_EDITION="$AOSP_EDITION"
    export PRODUCT_NAME="$AOSP_PRODUCT"
    ;;
  "$GMS_EDITION")
    "$ROOT_DIR/scripts/stage-gms-bundle.sh"
    GMS_STAGED=1
    export ACCESSIBLE_ANDROID_EDITION="$GMS_EDITION"
    export PRODUCT_NAME="$GMS_PRODUCT"
    ;;
  *)
    echo "ERROR: unknown edition: $EDITION" >&2
    echo "Valid editions: $AOSP_EDITION, $GMS_EDITION" >&2
    exit 2
    ;;
esac

echo "EDITION = $ACCESSIBLE_ANDROID_EDITION"
echo "PRODUCT = $PRODUCT_NAME"
echo "AOSP_DIR = $AOSP_DIR"

"$ROOT_DIR/scripts/build-pc-iso.sh"
