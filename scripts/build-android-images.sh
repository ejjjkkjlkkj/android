#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/upstream.env"

PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
RELEASE_CONFIG="${ANDROID_RELEASE_CONFIG:-aosp_current}"
VARIANT="${BUILD_VARIANT:-userdebug}"
LUNCH_TARGET="${PRODUCT}-${RELEASE_CONFIG}-${VARIANT}"
BUILD_JOBS="${ANDROID_BUILD_JOBS:-$(nproc 2>/dev/null || printf '8')}"

[[ -d "$AOSP_DIR/build" ]] || {
  echo "ERROR: AOSP tree not found at $AOSP_DIR" >&2
  echo "Run scripts/sync-aosp.sh first." >&2
  exit 2
}

[[ -s "$AOSP_DIR/device/accessibledroid/accessible_x86_64/prebuilt/kernel" ]] || {
  echo "ERROR: staged Android 17 kernel is missing." >&2
  echo "Run scripts/sync-kernel.sh, scripts/build-kernel.sh and scripts/stage-kernel.sh first." >&2
  exit 3
}

cd "$AOSP_DIR"
# shellcheck disable=SC1091
source build/envsetup.sh

echo "LUNCH_TARGET = $LUNCH_TARGET"
echo "ANDROID_BUILD_JOBS = $BUILD_JOBS"
lunch "$LUNCH_TARGET"

# Build the Android-native image set rather than depending on Android-x86 or
# AAropa's non-AOSP iso_img target. superimage pulls together the logical
# partitions; target-files-package records the canonical releasetools input.
m -j"$BUILD_JOBS" \
  bootimage \
  initbootimage \
  vendorbootimage \
  systemimage \
  systemextimage \
  productimage \
  vendorimage \
  superimage \
  userdataimage \
  vbmetaimage \
  target-files-package

PRODUCT_OUT="${OUT_DIR:-$AOSP_DIR/out/target/product/$PRODUCT}"
REQUIRED_IMAGES=(boot.img init_boot.img vendor_boot.img super.img userdata.img vbmeta.img)

for image in "${REQUIRED_IMAGES[@]}"; do
  [[ -s "$PRODUCT_OUT/$image" ]] || {
    echo "ERROR: required Android image missing after build: $PRODUCT_OUT/$image" >&2
    exit 4
  }
done

TARGET_FILES="$(find "$AOSP_DIR/out/target/product/$PRODUCT/obj/PACKAGING/target_files_intermediates" -maxdepth 1 -type f -name '*-target_files-*.zip' -print 2>/dev/null | sort | tail -n 1)"
if [[ -z "$TARGET_FILES" || ! -s "$TARGET_FILES" ]]; then
  echo "ERROR: target-files package was not produced" >&2
  exit 5
fi

MANIFEST="$PRODUCT_OUT/accessible-android-images.sha256"
{
  for image in "${REQUIRED_IMAGES[@]}"; do
    sha256sum "$PRODUCT_OUT/$image"
  done
  sha256sum "$TARGET_FILES"
} > "$MANIFEST"

echo "ANDROID_IMAGES = PASS"
echo "PRODUCT_OUT = $PRODUCT_OUT"
echo "TARGET_FILES = $TARGET_FILES"
cat "$MANIFEST"
