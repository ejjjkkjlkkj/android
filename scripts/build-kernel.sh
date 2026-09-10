#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/kernel.env"

[[ -d "$KERNEL_SRC_DIR/.repo" ]] || {
  echo "ERROR: kernel checkout not found at $KERNEL_SRC_DIR" >&2
  echo "Run scripts/sync-kernel.sh first." >&2
  exit 2
}

[[ -x "$KERNEL_SRC_DIR/tools/bazel" ]] || {
  echo "ERROR: Kleaf wrapper not found at $KERNEL_SRC_DIR/tools/bazel" >&2
  exit 3
}

rm -rf "$KERNEL_DIST_DIR"
mkdir -p "$KERNEL_DIST_DIR"

cd "$KERNEL_SRC_DIR"

echo "KERNEL_BUILD_TARGET = $KERNEL_BUILD_TARGET"
echo "KERNEL_DIST_TARGET = $KERNEL_DIST_TARGET"

# Build through the hermetic Kleaf wrapper supplied by the official Android
# kernel manifest. Do not source legacy build.config.x86_64.
tools/bazel build "$KERNEL_BUILD_TARGET"
tools/bazel run "$KERNEL_DIST_TARGET" -- --destdir="$KERNEL_DIST_DIR"

KERNEL_IMAGE="$KERNEL_DIST_DIR/$KERNEL_IMAGE_NAME"
[[ -s "$KERNEL_IMAGE" ]] || {
  echo "ERROR: expected kernel image was not produced: $KERNEL_IMAGE" >&2
  find "$KERNEL_DIST_DIR" -maxdepth 3 -type f -print >&2 || true
  exit 4
}

[[ -s "$KERNEL_DIST_DIR/initramfs.img" ]] || {
  echo "ERROR: virtual-device kernel dist did not produce initramfs.img" >&2
  exit 5
}

IFS=',' read -r -a required_modules <<< "$KERNEL_REQUIRED_VM_MODULES"
for module in "${required_modules[@]}"; do
  if ! find "$KERNEL_DIST_DIR" -type f -name "$module" -print -quit | grep -q .; then
    echo "ERROR: required VM kernel module is missing: $module" >&2
    exit 6
  fi
done

{
  sha256sum "$KERNEL_IMAGE"
  sha256sum "$KERNEL_DIST_DIR/initramfs.img"
} > "$KERNEL_DIST_DIR/SHA256SUMS"

find "$KERNEL_DIST_DIR" -type f -name '*.ko' -printf '%f\n' | sort -u > "$KERNEL_DIST_DIR/VM-MODULES.txt"

if [[ -f "$KERNEL_DIST_DIR/kernel.release" ]]; then
  echo "KERNEL_RELEASE = $(cat "$KERNEL_DIST_DIR/kernel.release")"
fi

echo "KERNEL_BUILD = PASS"
echo "KERNEL_IMAGE = $KERNEL_IMAGE"
echo "KERNEL_INITRAMFS = $KERNEL_DIST_DIR/initramfs.img"
echo "VM_MODULE_COUNT = $(wc -l < "$KERNEL_DIST_DIR/VM-MODULES.txt")"
cat "$KERNEL_DIST_DIR/SHA256SUMS"
