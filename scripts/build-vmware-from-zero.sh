#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/editions.env"

EDITION="${1:-$DEFAULT_EDITION}"

echo "=== ACCESSIBLEANDROID 17 VMWARE REBUILD FROM ZERO ==="
echo "EDITION = $EDITION"

bash "$ROOT_DIR/scripts/build-from-zero.sh" "$EDITION"

case "$EDITION" in
  "$AOSP_EDITION") PRODUCT_NAME="$AOSP_PRODUCT" ;;
  "$GMS_EDITION") PRODUCT_NAME="$GMS_PRODUCT" ;;
  *) echo "ERROR: unsupported edition: $EDITION" >&2; exit 2 ;;
esac
export PRODUCT_NAME

# build-edition already creates the ISO/images. Now create a persistent disk and
# the self-contained VMware Workstation bundle from the same product output.
EXPORT_ALL_FORMATS=1 bash "$ROOT_DIR/scripts/build-preinstalled-disk.sh"
bash "$ROOT_DIR/scripts/package-vmware-bundle.sh"

echo "ACCESSIBLEANDROID_VMWARE_FROM_ZERO = PASS"
echo "NEXT = boot the generated .vmx, then run scripts/verify-vmware-runtime-adb.sh"
