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
  find "$KERNEL_DIST_DIR" -maxdepth 2 -type f -print >&2 || true
  exit 4
}

sha256sum "$KERNEL_IMAGE" > "$KERNEL_DIST_DIR/SHA256SUMS"

if [[ -f "$KERNEL_DIST_DIR/kernel.release" ]]; then
  echo "KERNEL_RELEASE = $(cat "$KERNEL_DIST_DIR/kernel.release")"
fi

echo "KERNEL_BUILD = PASS"
echo "KERNEL_IMAGE = $KERNEL_IMAGE"
cat "$KERNEL_DIST_DIR/SHA256SUMS"
