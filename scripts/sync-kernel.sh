#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/kernel.env"

SYNC_JOBS="${KERNEL_SYNC_JOBS:-8}"

command -v repo >/dev/null 2>&1 || {
  echo "ERROR: repo is required. Run scripts/bootstrap-host.sh first." >&2
  exit 2
}

mkdir -p "$KERNEL_SRC_DIR"
cd "$KERNEL_SRC_DIR"

if [[ ! -d .repo ]]; then
  repo init --partial-clone \
    -u "$KERNEL_MANIFEST_URL" \
    -b "$KERNEL_MANIFEST_BRANCH"
fi

repo sync -c -j"$SYNC_JOBS" --fail-fast
repo manifest -r -o "$ROOT_DIR/config/kernel-pinned-manifest.xml"

test -x tools/bazel || {
  echo "ERROR: kernel manifest did not provide tools/bazel" >&2
  exit 3
}

test -f common/BUILD.bazel || {
  echo "ERROR: kernel/common BUILD.bazel is missing" >&2
  exit 4
}

echo "KERNEL_SYNC = PASS"
echo "KERNEL_FAMILY = $KERNEL_FAMILY"
echo "KERNEL_ARCH = $KERNEL_ARCH"
echo "KERNEL_SRC_DIR = $KERNEL_SRC_DIR"
echo "PINNED_MANIFEST = $ROOT_DIR/config/kernel-pinned-manifest.xml"
