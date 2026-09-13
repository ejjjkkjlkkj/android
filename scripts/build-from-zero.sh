#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/editions.env"

EDITION="${1:-$DEFAULT_EDITION}"
BOOTSTRAP_HOST="${BOOTSTRAP_HOST:-0}"
BOOTSTRAP_SDK="${BOOTSTRAP_SDK:-1}"
BUILD_KERNEL="${BUILD_KERNEL:-1}"

case "$EDITION" in
  "$AOSP_EDITION"|"$GMS_EDITION") ;;
  *)
    echo "ERROR: unknown edition: $EDITION" >&2
    echo "Valid editions: $AOSP_EDITION, $GMS_EDITION" >&2
    exit 2
    ;;
esac

mkdir -p "$BUILD_LOG_DIR" "$VM_ARTIFACT_DIR"
LOG_FILE="$BUILD_LOG_DIR/build-from-zero-${EDITION}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "PROJECT_ROOT = $PROJECT_ROOT"
echo "AOSP_DIR = $AOSP_DIR"
echo "ACCESSIBILITY_SRC_DIR = $ACCESSIBILITY_SRC_DIR"
echo "ANDROID_SDK_ROOT = $ANDROID_SDK_ROOT"
echo "KERNEL_SRC_DIR = $KERNEL_SRC_DIR"
echo "KERNEL_DIST_DIR = $KERNEL_DIST_DIR"
echo "VM_ARTIFACT_DIR = $VM_ARTIFACT_DIR"
echo "EDITION = $EDITION"

if [[ "$BOOTSTRAP_HOST" == "1" ]]; then
  "$ROOT_DIR/scripts/bootstrap-host.sh"
fi

if [[ "$BOOTSTRAP_SDK" == "1" ]]; then
  "$ROOT_DIR/scripts/bootstrap-android-sdk.sh"
fi

"$ROOT_DIR/scripts/sync-aosp.sh"
"$ROOT_DIR/scripts/sync-pc-upstreams.sh"
"$ROOT_DIR/scripts/sync-accessibility-upstreams.sh"
"$ROOT_DIR/scripts/install-device-tree.sh"

if [[ "$BUILD_KERNEL" == "1" ]]; then
  "$ROOT_DIR/scripts/sync-kernel.sh"
  "$ROOT_DIR/scripts/build-kernel.sh"
fi
"$ROOT_DIR/scripts/stage-kernel.sh"

"$ROOT_DIR/scripts/build-accessibility-apps.sh"
"$ROOT_DIR/scripts/build-edition.sh" "$EDITION"

echo "BUILD_FROM_ZERO = PASS"
echo "EDITION = $EDITION"
echo "LOG = $LOG_FILE"
