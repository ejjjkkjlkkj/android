#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/kernel.env"

REUSE_KERNEL_DIST="${REUSE_KERNEL_DIST:-0}"
PINNED_MANIFEST="$ROOT_DIR/config/kernel-pinned-manifest.xml"
CACHE_MARKER="$KERNEL_DIST_DIR/.kernel-build-input.sha256"

[[ -d "$KERNEL_SRC_DIR/.repo" ]] || {
  echo "ERROR: kernel checkout not found at $KERNEL_SRC_DIR" >&2
  echo "Run scripts/sync-kernel.sh first." >&2
  exit 2
}

[[ -x "$KERNEL_SRC_DIR/tools/bazel" ]] || {
  echo "ERROR: Kleaf wrapper not found at $KERNEL_SRC_DIR/tools/bazel" >&2
  exit 3
}

[[ -s "$PINNED_MANIFEST" ]] || {
  echo "ERROR: pinned kernel manifest is missing: $PINNED_MANIFEST" >&2
  echo "Run scripts/sync-kernel.sh first." >&2
  exit 7
}

kernel_build_fingerprint() {
  {
    sha256sum "$PINNED_MANIFEST"
    sha256sum "$ROOT_DIR/config/kernel.env"
    sha256sum "$ROOT_DIR/scripts/build-kernel.sh"
    printf 'build_target=%s\n' "$KERNEL_BUILD_TARGET"
    printf 'dist_target=%s\n' "$KERNEL_DIST_TARGET"
    printf 'image_name=%s\n' "$KERNEL_IMAGE_NAME"
    printf 'required_modules=%s\n' "$KERNEL_REQUIRED_VM_MODULES"
  } | sha256sum | awk '{print $1}'
}

validate_kernel_dist() {
  local image="$KERNEL_DIST_DIR/$KERNEL_IMAGE_NAME"
  local module

  [[ -s "$image" ]] || return 1
  [[ -s "$KERNEL_DIST_DIR/initramfs.img" ]] || return 1
  [[ -s "$KERNEL_DIST_DIR/SHA256SUMS" ]] || return 1

  IFS=',' read -r -a required_modules <<< "$KERNEL_REQUIRED_VM_MODULES"
  for module in "${required_modules[@]}"; do
    find "$KERNEL_DIST_DIR" -type f -name "$module" -print -quit | grep -q . || return 1
  done

  (cd "$KERNEL_DIST_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || return 1
  return 0
}

BUILD_FINGERPRINT="$(kernel_build_fingerprint)"

if [[ "$REUSE_KERNEL_DIST" == "1" && -s "$CACHE_MARKER" ]]; then
  cached_fingerprint="$(tr -d '[:space:]' < "$CACHE_MARKER")"
  if [[ "$cached_fingerprint" == "$BUILD_FINGERPRINT" ]] && validate_kernel_dist; then
    echo "KERNEL_BUILD_CACHE = HIT"
    echo "KERNEL_BUILD_FINGERPRINT = $BUILD_FINGERPRINT"
    echo "KERNEL_BUILD = PASS"
    echo "KERNEL_IMAGE = $KERNEL_DIST_DIR/$KERNEL_IMAGE_NAME"
    echo "KERNEL_INITRAMFS = $KERNEL_DIST_DIR/initramfs.img"
    if [[ -s "$KERNEL_DIST_DIR/VM-MODULES.txt" ]]; then
      echo "VM_MODULE_COUNT = $(wc -l < "$KERNEL_DIST_DIR/VM-MODULES.txt")"
    fi
    cat "$KERNEL_DIST_DIR/SHA256SUMS"
    exit 0
  fi
  echo "KERNEL_BUILD_CACHE = STALE"
fi

rm -rf "$KERNEL_DIST_DIR"
mkdir -p "$KERNEL_DIST_DIR"

cd "$KERNEL_SRC_DIR"

echo "KERNEL_BUILD_TARGET = $KERNEL_BUILD_TARGET"
echo "KERNEL_DIST_TARGET = $KERNEL_DIST_TARGET"
echo "KERNEL_BUILD_CACHE = MISS"

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

find "$KERNEL_DIST_DIR" -type f -name '*.ko' -printf '%f\n' | sort -u > "$KERNEL_DIST_DIR/VM-MODULES.txt"

(
  cd "$KERNEL_DIST_DIR"
  {
    sha256sum "$KERNEL_IMAGE_NAME" initramfs.img
    find . -type f -name '*.ko' -print0 | sort -z | xargs -0 -r sha256sum
  } > SHA256SUMS
)
printf '%s\n' "$BUILD_FINGERPRINT" > "$CACHE_MARKER"

if [[ -f "$KERNEL_DIST_DIR/kernel.release" ]]; then
  echo "KERNEL_RELEASE = $(cat "$KERNEL_DIST_DIR/kernel.release")"
fi

echo "KERNEL_BUILD_FINGERPRINT = $BUILD_FINGERPRINT"
echo "KERNEL_BUILD = PASS"
echo "KERNEL_IMAGE = $KERNEL_IMAGE"
echo "KERNEL_INITRAMFS = $KERNEL_DIST_DIR/initramfs.img"
echo "VM_MODULE_COUNT = $(wc -l < "$KERNEL_DIST_DIR/VM-MODULES.txt")"
cat "$KERNEL_DIST_DIR/SHA256SUMS"
