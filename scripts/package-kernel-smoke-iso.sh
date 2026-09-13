#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/kernel.env"

KERNEL="$KERNEL_DIST_DIR/$KERNEL_IMAGE_NAME"
INITRAMFS="$VM_ARTIFACT_DIR/accessible-android-kernel-smoke-initramfs.img"
ISO="$VM_ARTIFACT_DIR/AccessibleAndroid-17-kernel-smoke-x86_64.iso"
STAGE="$ROOT_DIR/.work/tmp/kernel-smoke-iso"

for command in grub-mkrescue xorriso sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $command" >&2
    exit 2
  }
done

[[ -s "$KERNEL" ]] || {
  echo "ERROR: Android kernel not found at $KERNEL" >&2
  echo "Run scripts/sync-kernel.sh and scripts/build-kernel.sh first." >&2
  exit 3
}

[[ -s "$INITRAMFS" ]] || "$ROOT_DIR/scripts/build-kernel-smoke-initramfs.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE/boot/grub" "$STAGE/android" "$VM_ARTIFACT_DIR"
install -m 0644 "$KERNEL" "$STAGE/android/kernel"
install -m 0644 "$INITRAMFS" "$STAGE/android/initramfs.img"

cat > "$STAGE/boot/grub/grub.cfg" <<'EOF'
set timeout=3
set default=0

menuentry 'AccessibleAndroid 17 kernel smoke test' --id accessible-android-smoke {
    echo 'Starting AccessibleAndroid Android 17 kernel smoke environment...'
    linux /android/kernel console=tty0 console=ttyS0,115200n8 earlycon=uart,io,0x3f8,115200n8 panic=-1 rdinit=/init
    initrd /android/initramfs.img
}
EOF

rm -f "$ISO" "$ISO.sha256"
grub-mkrescue -o "$ISO" "$STAGE" >/dev/null

[[ -s "$ISO" ]] || {
  echo "ERROR: grub-mkrescue did not produce an ISO" >&2
  exit 4
}

# Verify the resulting filesystem actually contains the boot payload.
xorriso -indev "$ISO" -find /android/kernel -exec report_lba -- >/dev/null 2>&1 || {
  echo "ERROR: packaged ISO does not contain /android/kernel" >&2
  exit 5
}
xorriso -indev "$ISO" -find /android/initramfs.img -exec report_lba -- >/dev/null 2>&1 || {
  echo "ERROR: packaged ISO does not contain /android/initramfs.img" >&2
  exit 6
}

sha256sum "$ISO" > "$ISO.sha256"
echo "KERNEL_SMOKE_ISO = PASS"
echo "ISO = $ISO"
cat "$ISO.sha256"
