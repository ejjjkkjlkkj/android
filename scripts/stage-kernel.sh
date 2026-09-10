#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/kernel.env"

SOURCE_KERNEL="$KERNEL_DIST_DIR/$KERNEL_IMAGE_NAME"
SOURCE_INITRAMFS="$KERNEL_DIST_DIR/initramfs.img"
TARGET_DIR="$AOSP_DIR/device/accessibledroid/accessible_x86_64/prebuilt"
TARGET_KERNEL="$TARGET_DIR/kernel"
TARGET_INITRAMFS="$TARGET_DIR/kernel-initramfs.img"
TARGET_MODULES_DIR="$TARGET_DIR/modules"

[[ -d "$AOSP_DIR/.repo" ]] || {
  echo "ERROR: AOSP checkout not found at $AOSP_DIR" >&2
  exit 2
}

[[ -s "$SOURCE_KERNEL" ]] || {
  echo "ERROR: built kernel not found at $SOURCE_KERNEL" >&2
  echo "Run scripts/build-kernel.sh first." >&2
  exit 3
}

[[ -s "$SOURCE_INITRAMFS" ]] || {
  echo "ERROR: virtual-device initramfs not found at $SOURCE_INITRAMFS" >&2
  echo "Run scripts/build-kernel.sh first." >&2
  exit 4
}

mkdir -p "$TARGET_DIR"
install -m 0644 "$SOURCE_KERNEL" "$TARGET_KERNEL"
install -m 0644 "$SOURCE_INITRAMFS" "$TARGET_INITRAMFS"

rm -rf "$TARGET_MODULES_DIR"
mkdir -p "$TARGET_MODULES_DIR"

# The Kleaf virtual-device dist can place modules in subdirectories. Android's
# BoardConfig consumes a flat prebuilt directory, so reject duplicate basenames
# instead of silently overwriting a module.
declare -A seen_module_names=()
module_count=0
while IFS= read -r -d '' module_path; do
  module_name="$(basename "$module_path")"
  if [[ -n "${seen_module_names[$module_name]:-}" ]]; then
    echo "ERROR: duplicate kernel module basename in dist: $module_name" >&2
    echo "First: ${seen_module_names[$module_name]}" >&2
    echo "Again: $module_path" >&2
    exit 5
  fi
  seen_module_names[$module_name]="$module_path"
  install -m 0644 "$module_path" "$TARGET_MODULES_DIR/$module_name"
  module_count=$((module_count + 1))
done < <(find "$KERNEL_DIST_DIR" -type f -name '*.ko' -print0)

[[ "$module_count" -gt 0 ]] || {
  echo "ERROR: no kernel modules were staged from $KERNEL_DIST_DIR" >&2
  exit 6
}

IFS=',' read -r -a required_modules <<< "$KERNEL_REQUIRED_VM_MODULES"
for module_name in "${required_modules[@]}"; do
  [[ -s "$TARGET_MODULES_DIR/$module_name" ]] || {
    echo "ERROR: required staged VM module is missing: $module_name" >&2
    exit 7
  }
done

{
  sha256sum "$TARGET_KERNEL"
  sha256sum "$TARGET_INITRAMFS"
  find "$TARGET_MODULES_DIR" -maxdepth 1 -type f -name '*.ko' -print0 \
    | sort -z \
    | xargs -0 sha256sum
} > "$TARGET_DIR/kernel-assets.sha256"

if [[ -f "$KERNEL_DIST_DIR/kernel.release" ]]; then
  install -m 0644 "$KERNEL_DIST_DIR/kernel.release" "$TARGET_DIR/kernel.release"
fi
if [[ -f "$KERNEL_DIST_DIR/VM-MODULES.txt" ]]; then
  install -m 0644 "$KERNEL_DIST_DIR/VM-MODULES.txt" "$TARGET_DIR/VM-MODULES.txt"
fi
if [[ -f "$KERNEL_DIST_DIR/modules.load" ]]; then
  install -m 0644 "$KERNEL_DIST_DIR/modules.load" "$TARGET_DIR/modules.load"
fi

[[ -s "$TARGET_KERNEL" && -s "$TARGET_INITRAMFS" ]] || {
  echo "ERROR: staged kernel assets are incomplete" >&2
  exit 8
}

echo "KERNEL_STAGE = PASS"
echo "TARGET_PREBUILT_KERNEL = $TARGET_KERNEL"
echo "TARGET_KERNEL_INITRAMFS = $TARGET_INITRAMFS"
echo "TARGET_KERNEL_MODULE_COUNT = $module_count"
cat "$TARGET_DIR/kernel-assets.sha256"
