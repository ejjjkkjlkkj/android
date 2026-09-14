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
MEM_TOTAL_KIB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || printf '0')"
MEM_TOTAL_GIB=$((MEM_TOTAL_KIB / 1024 / 1024))

# Android 17 Soong analysis is memory-heavy and happens before Ninja can make
# meaningful use of high parallelism. On the 32 GiB-class WSL runner, -j4 has
# already ended in exit 137. Keep enough headroom for Soong and the host.
if (( MEM_TOTAL_GIB > 0 && MEM_TOTAL_GIB <= 36 && BUILD_JOBS > 2 )); then
  echo "ANDROID_BUILD_JOBS_REQUESTED = $BUILD_JOBS"
  BUILD_JOBS=2
  echo "ANDROID_BUILD_JOBS_MEMORY_CAP = $BUILD_JOBS"
fi

release_pre_soong_memory() {
  local gradle_root="$ROOT_DIR/.work/tools"

  echo "==> Release build-tool memory before Soong"
  if [[ -d "$gradle_root" ]]; then
    while IFS= read -r gradle; do
      "$gradle" --stop >/dev/null 2>&1 || true
    done < <(find "$gradle_root" -maxdepth 3 -type f -path '*/bin/gradle' -perm -u+x 2>/dev/null | sort)
  fi

  if [[ -x "$ACCESSIBILITY_SRC_DIR/espeak-ng/android/gradlew" ]]; then
    (
      cd "$ACCESSIBILITY_SRC_DIR/espeak-ng/android"
      ./gradlew --stop >/dev/null 2>&1 || true
    )
  fi

  echo "MEMORY_BEFORE_SOONG ="
  free -h || true
  echo "SWAP_BEFORE_SOONG ="
  if command -v swapon >/dev/null 2>&1; then
    swapon --show || true
  fi
}

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

release_pre_soong_memory

cd "$AOSP_DIR"
# shellcheck disable=SC1091
source build/envsetup.sh

echo "LUNCH_TARGET = $LUNCH_TARGET"
echo "ANDROID_BUILD_JOBS = $BUILD_JOBS"
echo "HOST_MEM_TOTAL_GIB = $MEM_TOTAL_GIB"
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
