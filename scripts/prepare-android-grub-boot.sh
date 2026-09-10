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
BOOT_ARGS_FILE="$WORK_DIR/boot-mkbootimg-args.bin"
VENDOR_ARGS_FILE="$WORK_DIR/vendor-mkbootimg-args.bin"

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

run_unpack_mkbootimg_args() {
  local image="$1"
  local output="$2"
  local args_file="$3"
  if [[ -x "$UNPACK_TOOL" ]]; then
    "$UNPACK_TOOL" --boot_img "$image" --out "$output" --format=mkbootimg -0 > "$args_file"
  else
    python3 "$UNPACK_TOOL" --boot_img "$image" --out "$output" --format=mkbootimg -0 > "$args_file"
  fi
}

nul_argument_value() {
  local key="$1"
  local args_file="$2"
  local argument=""
  local take_next=0
  while IFS= read -r -d '' argument; do
    if [[ "$take_next" == "1" ]]; then
      printf '%s\n' "$argument"
      return 0
    fi
    if [[ "$argument" == "$key" ]]; then
      take_next=1
    fi
  done < "$args_file"
  return 1
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

# Re-run boot/vendor extraction in the machine-readable form AOSP explicitly
# provides for reconstructing mkbootimg arguments. Files are overwritten with
# identical extracted bytes while the NUL-delimited argument stream is saved.
run_unpack_mkbootimg_args "$BOOT_IMAGE" "$BOOT_OUT" "$BOOT_ARGS_FILE"
run_unpack_mkbootimg_args "$VENDOR_BOOT_IMAGE" "$VENDOR_OUT" "$VENDOR_ARGS_FILE"

BOOT_IMAGE_CMDLINE="$(nul_argument_value --cmdline "$BOOT_ARGS_FILE" || true)"
VENDOR_IMAGE_CMDLINE="$(nul_argument_value --vendor_cmdline "$VENDOR_ARGS_FILE" || true)"
printf '%s\n' "$BOOT_IMAGE_CMDLINE" > "$GRUB_OUT/aosp-boot-cmdline.txt"
printf '%s\n' "$VENDOR_IMAGE_CMDLINE" > "$GRUB_OUT/aosp-vendor-cmdline.txt"

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
# Android bootloader contract: generic ramdisk follows every vendor ramdisk.
cat "$INIT_OUT/ramdisk" >> "$GRUB_OUT/android-initrd.img"

bootconfig_enabled=0
if [[ -s "$VENDOR_OUT/bootconfig" ]]; then
  install -m 0644 "$VENDOR_OUT/bootconfig" "$GRUB_OUT/vendor-bootconfig.txt"
  # Linux requires bootconfig to be the final initrd section. The helper adds
  # NUL/padding, little-endian size/checksum, and #BOOTCONFIG\n, then verifies
  # the completed image before GRUB ever consumes it.
  python3 "$ROOT_DIR/scripts/bootconfig_tool.py" append \
    "$GRUB_OUT/android-initrd.img" "$GRUB_OUT/vendor-bootconfig.txt"
  python3 "$ROOT_DIR/scripts/bootconfig_tool.py" verify "$GRUB_OUT/android-initrd.img"
  bootconfig_enabled=1
fi

BOOTCONFIG_CMDLINE=""
if [[ "$bootconfig_enabled" == "1" ]]; then
  BOOTCONFIG_CMDLINE=" bootconfig"
fi

# Preserve the exact AOSP-generated boot and vendor command lines. Project
# overrides are appended last so the deterministic x86_64 PC contract wins if
# an inherited virtual-device default specifies a conflicting value.
cat > "$GRUB_OUT/kernel-cmdline.txt" <<EOF
${BOOT_IMAGE_CMDLINE} ${VENDOR_IMAGE_CMDLINE} init=/init security=selinux cma=0 firmware_class.path=/vendor/etc/ console=tty0 console=ttyS0,115200n8 panic=-1 printk.devkmsg=on 8250.nr_uarts=1 loop.max_part=7 androidboot.hardware=accessible_x86_64 androidboot.boot_devices=$ANDROID_BOOT_DEVICES androidboot.slot_suffix=_a androidboot.force_normal_boot=1 androidboot.verifiedbootstate=orange androidboot.vbmeta.device_state=unlocked${BOOTCONFIG_CMDLINE}
EOF

{
  echo "product=$PRODUCT"
  echo "ramdisk_format=$generic_format"
  echo "vendor_ramdisk_fragments=${#vendor_ramdisks[@]}"
  printf 'vendor_ramdisk=%s\n' "${vendor_ramdisks[@]##*/}"
  echo "android_boot_devices=$ANDROID_BOOT_DEVICES"
  echo "bootconfig_attached=$bootconfig_enabled"
  echo "aosp_boot_cmdline_present=$([[ -n "$BOOT_IMAGE_CMDLINE" ]] && echo 1 || echo 0)"
  echo "aosp_vendor_cmdline_present=$([[ -n "$VENDOR_IMAGE_CMDLINE" ]] && echo 1 || echo 0)"
} > "$GRUB_OUT/PROVENANCE.txt"

sha_tmp="$GRUB_OUT/.SHA256SUMS.tmp"
(
  cd "$GRUB_OUT"
  find . -maxdepth 1 -type f ! -name 'SHA256SUMS' ! -name '.SHA256SUMS.tmp' -print0 \
    | sort -z \
    | xargs -0 sha256sum > "$sha_tmp"
)
mv -f "$sha_tmp" "$GRUB_OUT/SHA256SUMS"

[[ -s "$GRUB_OUT/kernel" && -s "$GRUB_OUT/android-initrd.img" ]] || {
  echo "ERROR: direct boot assets are incomplete" >&2
  exit 9
}

echo "ANDROID_GRUB_BOOT_ASSETS = PASS"
echo "KERNEL = $GRUB_OUT/kernel"
echo "INITRD = $GRUB_OUT/android-initrd.img"
echo "RAMDISK_FORMAT = $generic_format"
echo "VENDOR_RAMDISK_FRAGMENTS = ${#vendor_ramdisks[@]}"
echo "BOOTCONFIG_ATTACHED = $bootconfig_enabled"
echo "ANDROID_BOOT_DEVICES = $ANDROID_BOOT_DEVICES"
