#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/vm.env"

PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
PRODUCT_OUT="${OUT_DIR:-$AOSP_DIR/out/target/product/$PRODUCT}"
DISK_DIR="$VM_ARTIFACT_DIR/preinstalled"
RAW_DISK="$DISK_DIR/AccessibleAndroid-17-${PRODUCT}-x86_64.raw"
QCOW2_DISK="$DISK_DIR/AccessibleAndroid-17-${PRODUCT}-x86_64.qcow2"
VDI_DISK="$DISK_DIR/AccessibleAndroid-17-${PRODUCT}-x86_64.vdi"
VMDK_DISK="$DISK_DIR/AccessibleAndroid-17-${PRODUCT}-x86_64.vmdk"
MANIFEST="$DISK_DIR/DISK-MANIFEST.txt"
PLAN_ONLY="${PLAN_ONLY:-0}"
EXPORT_ALL_FORMATS="${EXPORT_ALL_FORMATS:-1}"

DISK_SIZE_MIB=$((VM_DISK_SIZE_GIB * 1024))
FIXED_PARTITION_MIB=$((
  VM_BIOS_GRUB_SIZE_MIB + VM_ESP_SIZE_MIB +
  (2 * VM_BOOT_SIZE_MIB) + (2 * VM_INIT_BOOT_SIZE_MIB) +
  (2 * VM_VENDOR_BOOT_SIZE_MIB) + (2 * VM_VBMETA_SIZE_MIB) +
  VM_SUPER_SIZE_MIB + VM_METADATA_SIZE_MIB + VM_MISC_SIZE_MIB +
  VM_USERDATA_SIZE_MIB
))
# GPT begins at 1 MiB and keeps a small tail reserve for the backup table and
# future geometry evolution.
GEOMETRY_RESERVE_MIB=4

print_plan() {
  cat <<EOF
PREINSTALLED_DISK_PLAN
PRODUCT=$PRODUCT
DISK_SIZE_MIB=$DISK_SIZE_MIB
FIXED_PARTITION_MIB=$FIXED_PARTITION_MIB
FREE_AFTER_FIXED_MIB=$((DISK_SIZE_MIB - FIXED_PARTITION_MIB - GEOMETRY_RESERVE_MIB))
ANDROID_BOOT_DEVICES=$ANDROID_BOOT_DEVICES
VM_OS_DISK_PCI_ADDR=$VM_OS_DISK_PCI_ADDR

PARTITIONS:
1  $VM_GPT_LABEL_BIOS_GRUB ${VM_BIOS_GRUB_SIZE_MIB}MiB EF02
2  $VM_GPT_LABEL_ESP ${VM_ESP_SIZE_MIB}MiB EF00
3  $VM_GPT_LABEL_BOOT_A ${VM_BOOT_SIZE_MIB}MiB
4  $VM_GPT_LABEL_BOOT_B ${VM_BOOT_SIZE_MIB}MiB
5  $VM_GPT_LABEL_INIT_BOOT_A ${VM_INIT_BOOT_SIZE_MIB}MiB
6  $VM_GPT_LABEL_INIT_BOOT_B ${VM_INIT_BOOT_SIZE_MIB}MiB
7  $VM_GPT_LABEL_VENDOR_BOOT_A ${VM_VENDOR_BOOT_SIZE_MIB}MiB
8  $VM_GPT_LABEL_VENDOR_BOOT_B ${VM_VENDOR_BOOT_SIZE_MIB}MiB
9  $VM_GPT_LABEL_VBMETA_A ${VM_VBMETA_SIZE_MIB}MiB
10 $VM_GPT_LABEL_VBMETA_B ${VM_VBMETA_SIZE_MIB}MiB
11 $VM_GPT_LABEL_SUPER ${VM_SUPER_SIZE_MIB}MiB
12 $VM_GPT_LABEL_METADATA ${VM_METADATA_SIZE_MIB}MiB
13 $VM_GPT_LABEL_MISC ${VM_MISC_SIZE_MIB}MiB
14 $VM_GPT_LABEL_USERDATA ${VM_USERDATA_SIZE_MIB}MiB
EOF
}

if (( FIXED_PARTITION_MIB + GEOMETRY_RESERVE_MIB > DISK_SIZE_MIB )); then
  echo "ERROR: configured partitions do not fit in ${VM_DISK_SIZE_GIB} GiB" >&2
  print_plan >&2
  exit 2
fi

print_plan
if [[ "$PLAN_ONLY" == "1" ]]; then
  echo "PREINSTALLED_DISK_GEOMETRY = PASS"
  exit 0
fi

for command_name in qemu-img sgdisk losetup blockdev mkfs.vfat mkfs.ext4 mount umount grub-install sha256sum dd od stat sync; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 3
  }
done

ANDROID_IMAGES=(boot.img init_boot.img vendor_boot.img vbmeta.img super.img userdata.img)
for image in "${ANDROID_IMAGES[@]}"; do
  [[ -s "$PRODUCT_OUT/$image" ]] || {
    echo "ERROR: Android image missing: $PRODUCT_OUT/$image" >&2
    echo "Run scripts/build-android-images.sh first." >&2
    exit 4
  }
done

"$ROOT_DIR/scripts/prepare-android-grub-boot.sh"
GRUB_ASSETS="$VM_ARTIFACT_DIR/android-grub"
[[ -s "$GRUB_ASSETS/kernel" && -s "$GRUB_ASSETS/android-initrd.img" && -s "$GRUB_ASSETS/kernel-cmdline.txt" ]] || {
  echo "ERROR: direct Android boot assets are incomplete" >&2
  exit 5
}

if (( EUID == 0 )); then
  SUDO=()
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  SUDO=(sudo -n)
else
  echo "ERROR: passwordless sudo (or root) is required for loop-device GRUB installation" >&2
  exit 6
fi

SIM2IMG="$AOSP_DIR/out/host/linux-x86/bin/simg2img"
if [[ ! -x "$SIM2IMG" ]]; then
  SIM2IMG="$(command -v simg2img || true)"
fi

WORK_DIR="$ROOT_DIR/.work/tmp/preinstalled-disk"
ESP_MOUNT="$WORK_DIR/esp"
CONVERT_DIR="$WORK_DIR/converted"
LOOP_DEV=""
ESP_MOUNTED=0

cleanup() {
  set +e
  if [[ "$ESP_MOUNTED" == "1" ]]; then
    "${SUDO[@]}" umount "$ESP_MOUNT"
  fi
  if [[ -n "$LOOP_DEV" ]]; then
    "${SUDO[@]}" losetup -d "$LOOP_DEV"
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$WORK_DIR"
mkdir -p "$DISK_DIR" "$ESP_MOUNT" "$CONVERT_DIR"
rm -f "$RAW_DISK" "$QCOW2_DISK" "$VDI_DISK" "$VMDK_DISK" "$MANIFEST" "$DISK_DIR/SHA256SUMS"
qemu-img create -f raw "$RAW_DISK" "${VM_DISK_SIZE_GIB}G" >/dev/null

# The builder owns this newly created regular file. Never accept a caller
# supplied block-device destination in this script.
[[ -f "$RAW_DISK" && ! -b "$RAW_DISK" ]] || {
  echo "ERROR: refusing to partition a non-regular output" >&2
  exit 7
}

sgdisk --zap-all "$RAW_DISK" >/dev/null
sgdisk \
  -n 1:0:+"${VM_BIOS_GRUB_SIZE_MIB}M" -t 1:ef02 -c 1:"$VM_GPT_LABEL_BIOS_GRUB" \
  -n 2:0:+"${VM_ESP_SIZE_MIB}M" -t 2:ef00 -c 2:"$VM_GPT_LABEL_ESP" \
  -n 3:0:+"${VM_BOOT_SIZE_MIB}M" -t 3:8300 -c 3:"$VM_GPT_LABEL_BOOT_A" \
  -n 4:0:+"${VM_BOOT_SIZE_MIB}M" -t 4:8300 -c 4:"$VM_GPT_LABEL_BOOT_B" \
  -n 5:0:+"${VM_INIT_BOOT_SIZE_MIB}M" -t 5:8300 -c 5:"$VM_GPT_LABEL_INIT_BOOT_A" \
  -n 6:0:+"${VM_INIT_BOOT_SIZE_MIB}M" -t 6:8300 -c 6:"$VM_GPT_LABEL_INIT_BOOT_B" \
  -n 7:0:+"${VM_VENDOR_BOOT_SIZE_MIB}M" -t 7:8300 -c 7:"$VM_GPT_LABEL_VENDOR_BOOT_A" \
  -n 8:0:+"${VM_VENDOR_BOOT_SIZE_MIB}M" -t 8:8300 -c 8:"$VM_GPT_LABEL_VENDOR_BOOT_B" \
  -n 9:0:+"${VM_VBMETA_SIZE_MIB}M" -t 9:8300 -c 9:"$VM_GPT_LABEL_VBMETA_A" \
  -n 10:0:+"${VM_VBMETA_SIZE_MIB}M" -t 10:8300 -c 10:"$VM_GPT_LABEL_VBMETA_B" \
  -n 11:0:+"${VM_SUPER_SIZE_MIB}M" -t 11:8300 -c 11:"$VM_GPT_LABEL_SUPER" \
  -n 12:0:+"${VM_METADATA_SIZE_MIB}M" -t 12:8300 -c 12:"$VM_GPT_LABEL_METADATA" \
  -n 13:0:+"${VM_MISC_SIZE_MIB}M" -t 13:8300 -c 13:"$VM_GPT_LABEL_MISC" \
  -n 14:0:+"${VM_USERDATA_SIZE_MIB}M" -t 14:8300 -c 14:"$VM_GPT_LABEL_USERDATA" \
  "$RAW_DISK" >/dev/null
sgdisk -v "$RAW_DISK"

LOOP_DEV="$("${SUDO[@]}" losetup --find --show --partscan "$RAW_DISK")"
[[ -b "$LOOP_DEV" ]] || {
  echo "ERROR: failed to attach raw image to a loop device" >&2
  exit 8
}

partition_path() {
  local number="$1"
  if [[ -b "${LOOP_DEV}p${number}" ]]; then
    printf '%s\n' "${LOOP_DEV}p${number}"
  elif [[ -b "${LOOP_DEV}${number}" ]]; then
    printf '%s\n' "${LOOP_DEV}${number}"
  else
    return 1
  fi
}

for number in $(seq 1 14); do
  for _ in $(seq 1 50); do
    if partition_path "$number" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  partition_path "$number" >/dev/null || {
    echo "ERROR: loop partition $number did not appear" >&2
    exit 9
  }
done

P2="$(partition_path 2)"
P3="$(partition_path 3)"
P4="$(partition_path 4)"
P5="$(partition_path 5)"
P6="$(partition_path 6)"
P7="$(partition_path 7)"
P8="$(partition_path 8)"
P9="$(partition_path 9)"
P10="$(partition_path 10)"
P11="$(partition_path 11)"
P12="$(partition_path 12)"
P13="$(partition_path 13)"
P14="$(partition_path 14)"

is_android_sparse() {
  local image="$1"
  [[ "$(od -An -tx1 -N4 "$image" | tr -d ' \n')" == "3aff26ed" ]]
}

write_image() {
  local source_image="$1"
  local destination_partition="$2"
  local logical_name="$3"
  local raw_source="$source_image"
  local converted=""
  local image_size partition_size

  if is_android_sparse "$source_image"; then
    [[ -n "$SIM2IMG" && -x "$SIM2IMG" ]] || {
      echo "ERROR: $logical_name is Android sparse but simg2img is unavailable" >&2
      return 1
    }
    converted="$CONVERT_DIR/${logical_name}.raw"
    rm -f "$converted"
    "$SIM2IMG" "$source_image" "$converted"
    raw_source="$converted"
  fi

  image_size="$(stat -c '%s' "$raw_source")"
  partition_size="$("${SUDO[@]}" blockdev --getsize64 "$destination_partition")"
  if (( image_size > partition_size )); then
    echo "ERROR: $logical_name image ($image_size bytes) exceeds partition ($partition_size bytes)" >&2
    return 1
  fi

  echo "WRITE $logical_name -> $destination_partition ($image_size / $partition_size bytes)"
  "${SUDO[@]}" dd if="$raw_source" of="$destination_partition" bs=4M conv=fsync status=none
  [[ -z "$converted" ]] || rm -f "$converted"
}

write_image "$PRODUCT_OUT/boot.img" "$P3" boot_a
write_image "$PRODUCT_OUT/boot.img" "$P4" boot_b
write_image "$PRODUCT_OUT/init_boot.img" "$P5" init_boot_a
write_image "$PRODUCT_OUT/init_boot.img" "$P6" init_boot_b
write_image "$PRODUCT_OUT/vendor_boot.img" "$P7" vendor_boot_a
write_image "$PRODUCT_OUT/vendor_boot.img" "$P8" vendor_boot_b
write_image "$PRODUCT_OUT/vbmeta.img" "$P9" vbmeta_a
write_image "$PRODUCT_OUT/vbmeta.img" "$P10" vbmeta_b
write_image "$PRODUCT_OUT/super.img" "$P11" super
write_image "$PRODUCT_OUT/userdata.img" "$P14" userdata

# Metadata is intentionally a clean ext4 filesystem. misc remains zeroed until
# Android boot-control integration initializes the A/B control structure.
"${SUDO[@]}" mkfs.ext4 -q -F -L metadata "$P12"
"${SUDO[@]}" dd if=/dev/zero of="$P13" bs=1M count="$VM_MISC_SIZE_MIB" conv=fsync status=none

# Build one shared ESP used by both UEFI and BIOS GRUB. BIOS core.img is embedded
# in partition 1 (EF02); UEFI uses EFI/BOOT/BOOTX64.EFI in partition 2.
"${SUDO[@]}" mkfs.vfat -F 32 -n ACCESSIBLE "$P2" >/dev/null
"${SUDO[@]}" mount "$P2" "$ESP_MOUNT"
ESP_MOUNTED=1
"${SUDO[@]}" mkdir -p "$ESP_MOUNT/android" "$ESP_MOUNT/boot/grub"
"${SUDO[@]}" install -m 0644 "$GRUB_ASSETS/kernel" "$ESP_MOUNT/android/kernel"
"${SUDO[@]}" install -m 0644 "$GRUB_ASSETS/android-initrd.img" "$ESP_MOUNT/android/android-initrd.img"

ANDROID_CMDLINE="$(tr '\n' ' ' < "$GRUB_ASSETS/kernel-cmdline.txt" | sed 's/[[:space:]]*$//')"
GRUB_CFG="$WORK_DIR/grub.cfg"
cat > "$GRUB_CFG" <<EOF
set timeout=0
set default=0

menuentry 'AccessibleAndroid 17' --id accessible-android {
    linux /android/kernel $ANDROID_CMDLINE
    initrd /android/android-initrd.img
}
EOF
"${SUDO[@]}" install -m 0644 "$GRUB_CFG" "$ESP_MOUNT/boot/grub/grub.cfg"

"${SUDO[@]}" grub-install \
  --target=x86_64-efi \
  --efi-directory="$ESP_MOUNT" \
  --boot-directory="$ESP_MOUNT/boot" \
  --removable --no-nvram "$LOOP_DEV"
[[ -s "$ESP_MOUNT/EFI/BOOT/BOOTX64.EFI" ]] || {
  echo "ERROR: UEFI removable bootloader was not installed" >&2
  exit 10
}

"${SUDO[@]}" grub-install \
  --target=i386-pc \
  --boot-directory="$ESP_MOUNT/boot" \
  --recheck "$LOOP_DEV"

sync
"${SUDO[@]}" umount "$ESP_MOUNT"
ESP_MOUNTED=0
"${SUDO[@]}" losetup -d "$LOOP_DEV"
LOOP_DEV=""

sgdisk -v "$RAW_DISK"
sgdisk -p "$RAW_DISK" > "$DISK_DIR/GPT.txt"

qemu-img convert -p -f raw -O qcow2 -o compat=1.1,lazy_refcounts=on "$RAW_DISK" "$QCOW2_DISK"
if [[ "$EXPORT_ALL_FORMATS" == "1" ]]; then
  qemu-img convert -p -f raw -O vdi "$RAW_DISK" "$VDI_DISK"
  qemu-img convert -p -f raw -O vmdk -o subformat=streamOptimized "$RAW_DISK" "$VMDK_DISK"
fi

{
  echo "schema=1"
  echo "product=$PRODUCT"
  echo "android_api=37"
  echo "disk_size_gib=$VM_DISK_SIZE_GIB"
  echo "android_boot_devices=$ANDROID_BOOT_DEVICES"
  echo "os_disk_pci_addr=$VM_OS_DISK_PCI_ADDR"
  echo "bios_grub=installed"
  echo "uefi_grub=installed"
  echo "slot=a"
  echo "userdata_size_mib=$VM_USERDATA_SIZE_MIB"
  echo
  sgdisk -p "$RAW_DISK"
} > "$MANIFEST"

sha_tmp="$DISK_DIR/.SHA256SUMS.tmp"
(
  cd "$DISK_DIR"
  files=("$(basename "$QCOW2_DISK")" "GPT.txt" "$(basename "$MANIFEST")")
  if [[ "$EXPORT_ALL_FORMATS" == "1" ]]; then
    files+=("$(basename "$VDI_DISK")" "$(basename "$VMDK_DISK")")
  fi
  sha256sum "${files[@]}" > "$sha_tmp"
)
mv -f "$sha_tmp" "$DISK_DIR/SHA256SUMS"

qemu-img info "$QCOW2_DISK"
if [[ "$EXPORT_ALL_FORMATS" == "1" ]]; then
  qemu-img info "$VDI_DISK"
  qemu-img info "$VMDK_DISK"
fi

echo "PREINSTALLED_ANDROID_DISK = PASS"
echo "RAW = $RAW_DISK"
echo "QCOW2 = $QCOW2_DISK"
if [[ "$EXPORT_ALL_FORMATS" == "1" ]]; then
  echo "VDI = $VDI_DISK"
  echo "VMDK = $VMDK_DISK"
fi
echo "BIOS_GRUB = PASS"
echo "UEFI_GRUB = PASS"
echo "ANDROID_BOOT_DEVICES = $ANDROID_BOOT_DEVICES"
cat "$DISK_DIR/SHA256SUMS"
