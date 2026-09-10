#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/kernel.env"

SOURCE_KERNEL="$KERNEL_DIST_DIR/$KERNEL_IMAGE_NAME"
TARGET_DIR="$AOSP_DIR/device/accessibledroid/accessible_x86_64/prebuilt"
TARGET_KERNEL="$TARGET_DIR/kernel"

[[ -d "$AOSP_DIR/.repo" ]] || {
  echo "ERROR: AOSP checkout not found at $AOSP_DIR" >&2
  exit 2
}

[[ -s "$SOURCE_KERNEL" ]] || {
  echo "ERROR: built kernel not found at $SOURCE_KERNEL" >&2
  echo "Run scripts/build-kernel.sh first." >&2
  exit 3
}

mkdir -p "$TARGET_DIR"
install -m 0644 "$SOURCE_KERNEL" "$TARGET_KERNEL"
sha256sum "$TARGET_KERNEL" > "$TARGET_DIR/kernel.sha256"

if [[ -f "$KERNEL_DIST_DIR/kernel.release" ]]; then
  install -m 0644 "$KERNEL_DIST_DIR/kernel.release" "$TARGET_DIR/kernel.release"
fi

[[ -s "$TARGET_KERNEL" ]] || {
  echo "ERROR: staged kernel is empty" >&2
  exit 4
}

echo "KERNEL_STAGE = PASS"
echo "TARGET_PREBUILT_KERNEL = $TARGET_KERNEL"
cat "$TARGET_DIR/kernel.sha256"
