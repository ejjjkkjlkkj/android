#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/upstream.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/vm.env"

PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
PRODUCT_OUT="${OUT_DIR:-$AOSP_DIR/out/target/product/$PRODUCT}"
WORK_DIR="$ROOT_DIR/.work/tmp/android-grub-boot"
BOOT_OUT="$WORK_DIR/boot"
INIT_OUT="$WORK_DIR/init_boot"
VENDOR_OUT="$WORK_DIR/vendor_boot"
GRUB_OUT="$VM_ARTIFACT_DIR/android-grub"

BOOT_IMAGE="$PRODUCT_OUT/boot.img"
INIT_BOOT_IMAGE="$PRODUCT_OUT/init_boot.img"
VENDOR_BOOT_IMAGE="$PRODUCT_OUT/vendor_boot.img"

for image in "$BOOT_IMAGE" "$INIT_BOOT_IMAGE" "$VENDOR_BOOT_IMAGE"; do
  [[ -s "$image" ]] || {
    echo "ERROR: required Android boot image is missing: $image" >&2
    echo "Run scripts/build-android-images.sh first." >&2
    exit 2
  }
done

UNPACK_TOOL="$AOSP_DIR/out/host/linux-x86/bin/unpack_bootimg"
if [[ ! -x "$UNPACK_TOOL" ]]; then
  UNPACK_TOOL="$AOSP_DIR/system/tools/mkbootimg/unpack_bootimg.py"
fi
[[ -f "$UNPACK_TOOL" ]] || {
  echo "ERROR: unpack_bootimg not found in AOSP checkout/output" >&2
  exit 3
}

run_unpack() {
  local image="$1"
  local output="$2"
  if [[ -x "$UNPACK_TOOL" ]]; then
    "$UNPACK_TOOL" --boot_img "$image" --out "$output"
  else
    python3 "$UNPACK_TOOL" --boot_img "$image" --out "$output"
  fi
}

ramdisk_format() {
  local image="$1"
  local magic
  magic="$(od -An -tx1 -N4 "$image" | tr -d ' \n')"
  case "$magic" in
    02214c18|04224d18) printf 'lz4\n' ;;
    1f8b*) printf 'gzip\n' ;;
    *) printf 'unknown:%s\n' "$magic" ;;
  esac
}

rm -rf "$WORK_DIR" "$GRUB_OUT"
mkdir -p "$BOOT_OUT" "$INIT_OUT" "$VENDOR_OUT" "$GRUB_OUT"

run_unpack "$BOOT_IMAGE" "$BOOT_OUT" > "$GRUB_OUT/boot-image-info.txt"
run_unpack "$INIT_BOOT_IMAGE" "$INIT_OUT" > "$GRUB_OUT/init-boot-image-info.txt"
run_unpack "$VENDOR_BOOT_IMAGE" "$VENDOR_OUT" > "$GRUB_OUT/vendor-boot-image-info.txt"

[[ -s "$BOOT_OUT/kernel" ]] || {
  echo "ERROR: boot.img did not contain a kernel" >&2
  exit 4
}
[[ -s "$INIT_OUT/ramdisk" ]] || {
  echo "ERROR: init_boot.img did not contain the generic ramdisk" >&2
  exit 5
}

mapfile -d '' vendor_ramdisks < <(
  find "$VENDOR_OUT" -maxdepth 1 -type f \
    \( -name 'vendor_ramdisk' -o -name 'vendor_ramdisk[0-9][0-9]' \) \
    -print0 | sort -z
)
[[ "${#vendor_ramdisks[@]}" -gt 0 ]] || {
  echo "ERROR: vendor_boot.img did not contain a vendor ramdisk" >&2
  exit 6
}

generic_format="$(ramdisk_format "$INIT_OUT/ramdisk")"
[[ "$generic_format" != unknown:* ]] || {
  echo "ERROR: unsupported generic ramdisk compression: $generic_format" >&2
  exit 7
}

for ramdisk in "${vendor_ramdisks[@]}"; do
  format="$(ramdisk_format "$ramdisk")"
  [[ "$format" == "$generic_format" ]] || {
    echo "ERROR: vendor and generic ramdisk compression differs" >&2
    echo "generic=$generic_format vendor=$format file=$ramdisk" >&2
    exit 8
  }
done

install -m 0644 "$BOOT_OUT/kernel" "$GRUB_OUT/kernel"
: > "$GRUB_OUT/android-initrd.img"
for ramdisk in "${vendor_ramdisks[@]}"; do
  cat "$ramdisk" >> "$GRUB_OUT/android-initrd.img"
done
# Android bootloader contract: generic ramdisk must be last and directly
# adjacent to the vendor ramdisk data.
cat "$INIT_OUT/ramdisk" >> "$GRUB_OUT/android-initrd.img"

if [[ -s "$VENDOR_OUT/bootconfig" ]]; then
  install -m 0644 "$VENDOR_OUT/bootconfig" "$GRUB_OUT/vendor-bootconfig.txt"
fi

cat > "$GRUB_OUT/kernel-cmdline.txt" <<EOF
console=tty0 console=ttyS0,115200n8 panic=-1 printk.devkmsg=on 8250.nr_uarts=1 loop.max_part=7 androidboot.hardware=accessible_x86_64 androidboot.boot_devices=$ANDROID_BOOT_DEVICES androidboot.slot_suffix=_a androidboot.force_normal_boot=1 androidboot.verifiedbootstate=orange androidboot.vbmeta.device_state=unlocked
EOF

{
  echo "product=$PRODUCT"
  echo "ramdisk_format=$generic_format"
  echo "vendor_ramdisk_fragments=${#vendor_ramdisks[@]}"
  printf 'vendor_ramdisk=%s\n' "${vendor_ramdisks[@]##*/}"
  echo "android_boot_devices=$ANDROID_BOOT_DEVICES"
} > "$GRUB_OUT/PROVENANCE.txt"

(
  cd "$GRUB_OUT"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 sha256sum > SHA256SUMS
)

[[ -s "$GRUB_OUT/kernel" && -s "$GRUB_OUT/android-initrd.img" ]] || {
  echo "ERROR: direct boot assets are incomplete" >&2
  exit 9
}

echo "ANDROID_GRUB_BOOT_ASSETS = PASS"
echo "KERNEL = $GRUB_OUT/kernel"
echo "INITRD = $GRUB_OUT/android-initrd.img"
echo "RAMDISK_FORMAT = $generic_format"
echo "VENDOR_RAMDISK_FRAGMENTS = ${#vendor_ramdisks[@]}"
echo "ANDROID_BOOT_DEVICES = $ANDROID_BOOT_DEVICES"
