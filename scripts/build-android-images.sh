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
SWAP_TARGET_GIB="${ANDROID_BUILD_SWAP_TARGET_GIB:-32}"
SWAP_MAX_ADD_GIB="${ANDROID_BUILD_SWAP_MAX_ADD_GIB:-16}"
SWAP_FILE="${ANDROID_BUILD_SWAP_FILE:-$ROOT_DIR/.work/accessibleandroid-build.swap}"

# Android 17 Soong analysis is memory-heavy and happens before Ninja can make
# meaningful use of high parallelism. On the 32 GiB-class WSL runner, -j4 has
# already ended in exit 137. Keep enough headroom for Soong and the host.
if (( MEM_TOTAL_GIB > 0 && MEM_TOTAL_GIB <= 36 && BUILD_JOBS > 2 )); then
  echo "ANDROID_BUILD_JOBS_REQUESTED = $BUILD_JOBS"
  BUILD_JOBS=2
  echo "ANDROID_BUILD_JOBS_MEMORY_CAP = $BUILD_JOBS"
fi

# Keep the effective value visible to child processes and to later GitHub
# Actions steps. The workflow may initially select a higher value before this
# script applies its memory-aware cap.
export ANDROID_BUILD_JOBS="$BUILD_JOBS"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'ANDROID_BUILD_JOBS=%s\n' "$BUILD_JOBS" >> "$GITHUB_ENV"
fi

ensure_build_swap() {
  local swap_total_kib swap_total_gib add_gib free_kib required_kib
  local -a sudo_cmd=()

  # The extra swap is only a safety net for constrained WSL/self-hosted builds.
  # Large native builders should keep their host-managed memory policy untouched.
  if (( MEM_TOTAL_GIB == 0 || MEM_TOTAL_GIB > 36 )); then
    echo "ANDROID_BUILD_SWAP = NOT_NEEDED"
    return 0
  fi

  command -v swapon >/dev/null 2>&1 || {
    echo "ANDROID_BUILD_SWAP = SKIP_NO_SWAPON"
    return 0
  }
  command -v mkswap >/dev/null 2>&1 || {
    echo "ANDROID_BUILD_SWAP = SKIP_NO_MKSWAP"
    return 0
  }
  command -v fallocate >/dev/null 2>&1 || {
    echo "ANDROID_BUILD_SWAP = SKIP_NO_FALLOCATE"
    return 0
  }

  if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
      sudo_cmd=(sudo -n)
    else
      echo "ANDROID_BUILD_SWAP = SKIP_NO_PRIVILEGE"
      return 0
    fi
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fxq "$SWAP_FILE"; then
    echo "ANDROID_BUILD_SWAP = ACTIVE"
    return 0
  fi

  swap_total_kib="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || printf '0')"
  swap_total_gib=$((swap_total_kib / 1024 / 1024))
  if (( swap_total_gib >= SWAP_TARGET_GIB )); then
    echo "ANDROID_BUILD_SWAP = HOST_SUFFICIENT"
    echo "ANDROID_BUILD_SWAP_TOTAL_GIB = $swap_total_gib"
    return 0
  fi

  add_gib=$((SWAP_TARGET_GIB - swap_total_gib))
  (( add_gib > SWAP_MAX_ADD_GIB )) && add_gib=$SWAP_MAX_ADD_GIB
  (( add_gib < 1 )) && add_gib=1

  mkdir -p "$(dirname "$SWAP_FILE")"
  free_kib="$(df -Pk "$(dirname "$SWAP_FILE")" | awk 'NR==2 {print $4}')"
  required_kib=$(((add_gib + 8) * 1024 * 1024))
  if (( free_kib < required_kib )); then
    echo "ANDROID_BUILD_SWAP = SKIP_LOW_DISK"
    echo "ANDROID_BUILD_SWAP_REQUEST_GIB = $add_gib"
    echo "ANDROID_BUILD_SWAP_FREE_KIB = $free_kib"
    return 0
  fi

  # Recreate only our dedicated project swap file. Never touch host swap devices.
  if [[ -e "$SWAP_FILE" ]]; then
    rm -f "$SWAP_FILE"
  fi
  fallocate -l "${add_gib}G" "$SWAP_FILE"
  chmod 600 "$SWAP_FILE"
  "${sudo_cmd[@]}" mkswap "$SWAP_FILE" >/dev/null
  if "${sudo_cmd[@]}" swapon "$SWAP_FILE"; then
    echo "ANDROID_BUILD_SWAP = ENABLED"
    echo "ANDROID_BUILD_SWAP_ADDED_GIB = $add_gib"
  else
    echo "ANDROID_BUILD_SWAP = ENABLE_FAILED"
    rm -f "$SWAP_FILE"
    return 0
  fi
}

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

  ensure_build_swap

  echo "MEMORY_BEFORE_SOONG ="
  free -h || true
  echo "MEMORY_PSI_BEFORE_SOONG ="
  if [[ -r /proc/pressure/memory ]]; then
    cat /proc/pressure/memory || true
  else
    echo "unavailable"
  fi
  echo "SWAP_BEFORE_SOONG ="
  if command -v swapon >/dev/null 2>&1; then
    swapon --show || true
  fi
  echo "DISK_BEFORE_SOONG ="
  df -h "$ROOT_DIR" "$AOSP_DIR" || true
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

# AOSP's generic x86_64 boot rules consume the kernel from the product output
# directory. The AccessibleAndroid board supplies a verified prebuilt GKI
# kernel, so materialize that input before Ninja schedules bootimage.
PRODUCT_DEVICE_DIR="$AOSP_DIR/out/target/product/accessible_x86_64"
mkdir -p "$PRODUCT_DEVICE_DIR"
install -m 0644 \
  "$AOSP_DIR/device/accessibledroid/accessible_x86_64/prebuilt/kernel" \
  "$PRODUCT_DEVICE_DIR/kernel"
echo "PREBUILT_KERNEL_OUTPUT = $PRODUCT_DEVICE_DIR/kernel"

# The generic AOSP x86_64 board normally enables x86 as a second architecture.
# AccessibleAndroid intentionally removes that secondary ABI to keep the guest
# and the Soong graph x86_64-only. Fail before expensive graph analysis if a
# future AOSP/product change silently restores the 32-bit target.
echo "TARGET_ARCH_EFFECTIVE = ${TARGET_ARCH:-<unset>}"
echo "TARGET_2ND_ARCH_EFFECTIVE = ${TARGET_2ND_ARCH:-<none>}"
if [[ "${TARGET_ARCH:-}" != "x86_64" ]]; then
  echo "ERROR: AccessibleAndroid requires TARGET_ARCH=x86_64" >&2
  exit 6
fi
if [[ -n "${TARGET_2ND_ARCH:-}" ]]; then
  echo "ERROR: AccessibleAndroid must be x86_64-only; secondary architecture detected: $TARGET_2ND_ARCH" >&2
  exit 7
fi
echo "ANDROID_X86_64_ONLY_RUNTIME = PASS"

# A previously interrupted Soong run can leave a partial graph that causes
# soong_ui to panic before it has a chance to regenerate the Ninja graph.
# Detect that stale state and reset only the derived Soong metadata; the
# synchronized AOSP checkout and reusable kernel/app caches remain intact.
rm -rf "$AOSP_DIR/out/soong" "$AOSP_DIR/out/.module_paths"
echo "AOSP_SOONG_STATE_RESET = PASS (fresh graph)"

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
