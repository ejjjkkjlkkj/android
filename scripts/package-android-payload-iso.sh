#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/upstream.env"

PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
PRODUCT_OUT="${OUT_DIR:-$AOSP_DIR/out/target/product/$PRODUCT}"
KERNEL="$KERNEL_DIST_DIR/bzImage"
SMOKE_INITRAMFS="$VM_ARTIFACT_DIR/accessible-android-kernel-smoke-initramfs.img"
DIRECT_BOOT_DIR="$VM_ARTIFACT_DIR/android-grub"
ISO="$VM_ARTIFACT_DIR/AccessibleAndroid-17-${PRODUCT}-installer-preview.iso"
STAGE="$ROOT_DIR/.work/tmp/android-payload-iso"
CHUNK_BYTES="${PAYLOAD_CHUNK_BYTES:-1073741824}"

for command_name in grub-mkrescue xorriso sha256sum split stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

[[ -s "$KERNEL" ]] || {
  echo "ERROR: kernel not found at $KERNEL" >&2
  exit 3
}
[[ -s "$SMOKE_INITRAMFS" ]] || "$ROOT_DIR/scripts/build-kernel-smoke-initramfs.sh"

ANDROID_IMAGES=(boot.img init_boot.img vendor_boot.img vbmeta.img super.img userdata.img)
for image in "${ANDROID_IMAGES[@]}"; do
  [[ -s "$PRODUCT_OUT/$image" ]] || {
    echo "ERROR: Android image missing: $PRODUCT_OUT/$image" >&2
    echo "Run scripts/build-android-images.sh first." >&2
    exit 4
  }
done

# Prepare the real Android first-stage initramfs by following the Android GKI
# bootloader contract: vendor ramdisk fragment(s), then generic init_boot ramdisk.
"$ROOT_DIR/scripts/prepare-android-grub-boot.sh"
[[ -s "$DIRECT_BOOT_DIR/kernel" && -s "$DIRECT_BOOT_DIR/android-initrd.img" ]] || {
  echo "ERROR: direct Android GRUB assets were not produced" >&2
  exit 5
}
DIRECT_CMDLINE="$(tr '\n' ' ' < "$DIRECT_BOOT_DIR/kernel-cmdline.txt" | sed -E 's/[[:space:]]+$//')"

rm -rf "$STAGE"
mkdir -p "$STAGE/boot/grub" "$STAGE/android/direct" "$STAGE/payload" "$VM_ARTIFACT_DIR"
install -m 0644 "$KERNEL" "$STAGE/android/kernel"
install -m 0644 "$SMOKE_INITRAMFS" "$STAGE/android/installer-initramfs.img"
install -m 0644 "$DIRECT_BOOT_DIR/kernel" "$STAGE/android/direct/kernel"
install -m 0644 "$DIRECT_BOOT_DIR/android-initrd.img" "$STAGE/android/direct/android-initrd.img"
install -m 0644 "$DIRECT_BOOT_DIR/kernel-cmdline.txt" "$STAGE/android/direct/kernel-cmdline.txt"
install -m 0644 "$DIRECT_BOOT_DIR/PROVENANCE.txt" "$STAGE/android/direct/PROVENANCE.txt"
install -m 0644 "$DIRECT_BOOT_DIR/SHA256SUMS" "$STAGE/android/direct/SHA256SUMS"
[[ ! -s "$DIRECT_BOOT_DIR/vendor-bootconfig.txt" ]] || \
  install -m 0644 "$DIRECT_BOOT_DIR/vendor-bootconfig.txt" "$STAGE/android/direct/vendor-bootconfig.txt"

cat > "$STAGE/boot/grub/grub.cfg" <<'EOF'
set timeout=8
set default=0

menuentry 'AccessibleAndroid 17 installer bootstrap - safe diagnostics' --id accessible-android-installer {
    echo 'Starting non-destructive AccessibleAndroid installer bootstrap...'
    linux /android/kernel console=tty0 console=ttyS0,115200n8 earlycon=uart,io,0x3f8,115200n8 panic=-1 rdinit=/init
    initrd /android/installer-initramfs.img
}
EOF

cat >> "$STAGE/boot/grub/grub.cfg" <<EOF

menuentry 'AccessibleAndroid 17 direct boot - experimental' --id accessible-android-direct {
    echo 'Starting Android 17 first-stage init from vendor_boot + init_boot...'
    echo 'A preinstalled AccessibleAndroid GPT disk is required at PCI 0000:00:06.0.'
    linux /android/direct/kernel $DIRECT_CMDLINE
    initrd /android/direct/android-initrd.img
}
EOF

cat > "$STAGE/README.txt" <<'EOF'
AccessibleAndroid 17 x86_64 installer preview media

This engineering image is bootable in BIOS and UEFI modes and contains the
Android installation payload plus integrity metadata.

The DEFAULT installer-bootstrap entry is NON-DESTRUCTIVE: it opens a serial/text
diagnostics shell and does not modify a disk.

The second GRUB entry boots the real Android 17 first-stage initramfs assembled
from vendor_boot + init_boot. It requires the project preinstalled GPT disk at
the deterministic virtio PCI address documented in config/vm.env.
EOF

MANIFEST="$STAGE/payload/MANIFEST.txt"
: > "$MANIFEST"
printf 'schema=1\nandroid_api=37\nproduct=%s\nchunk_bytes=%s\n\n' "$PRODUCT" "$CHUNK_BYTES" >> "$MANIFEST"

for image in "${ANDROID_IMAGES[@]}"; do
  src="$PRODUCT_OUT/$image"
  size="$(stat -c '%s' "$src")"
  digest="$(sha256sum "$src" | awk '{print $1}')"
  printf 'image=%s size=%s sha256=%s\n' "$image" "$size" "$digest" >> "$MANIFEST"

  if (( size > CHUNK_BYTES )); then
    prefix="$STAGE/payload/${image}.part-"
    split -b "$CHUNK_BYTES" -d -a 4 "$src" "$prefix"
    while IFS= read -r -d '' chunk; do
      chunk_name="$(basename "$chunk")"
      chunk_size="$(stat -c '%s' "$chunk")"
      chunk_digest="$(sha256sum "$chunk" | awk '{print $1}')"
      printf 'chunk=%s parent=%s size=%s sha256=%s\n' "$chunk_name" "$image" "$chunk_size" "$chunk_digest" >> "$MANIFEST"
    done < <(find "$STAGE/payload" -maxdepth 1 -type f -name "${image}.part-*" -print0 | sort -z)
  else
    install -m 0644 "$src" "$STAGE/payload/$image"
  fi
  printf '\n' >> "$MANIFEST"
done

# Hash every file actually stored on the optical medium. This is separate from
# MANIFEST.txt, which also records hashes of the unsplit original Android images.
(
  cd "$STAGE"
  find android payload -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 sha256sum > payload/SHA256SUMS
)

rm -f "$ISO" "$ISO.sha256"
grub-mkrescue -o "$ISO" "$STAGE" >/dev/null
[[ -s "$ISO" ]] || {
  echo "ERROR: failed to produce payload ISO" >&2
  exit 6
}

for required in \
  /android/kernel \
  /android/installer-initramfs.img \
  /android/direct/kernel \
  /android/direct/android-initrd.img \
  /payload/MANIFEST.txt \
  /payload/SHA256SUMS; do
  xorriso -indev "$ISO" -find "$required" -exec report_lba -- >/dev/null 2>&1 || {
    echo "ERROR: ISO is missing required path: $required" >&2
    exit 7
  }
done

sha256sum "$ISO" > "$ISO.sha256"
echo "ANDROID_PAYLOAD_ISO = PASS"
echo "MODE = NON_DESTRUCTIVE_INSTALLER_PREVIEW_WITH_EXPERIMENTAL_DIRECT_ANDROID_BOOT"
echo "ISO = $ISO"
cat "$ISO.sha256"
