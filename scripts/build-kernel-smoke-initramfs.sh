#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"

BUSYBOX="${BUSYBOX:-$(command -v busybox || true)}"
OUTPUT="$VM_ARTIFACT_DIR/accessible-android-kernel-smoke-initramfs.img"
ROOTFS="$ROOT_DIR/.work/tmp/kernel-smoke-rootfs"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

[[ -n "$BUSYBOX" && -x "$BUSYBOX" ]] || {
  echo "ERROR: busybox is required. Run scripts/bootstrap-host.sh first." >&2
  exit 2
}

[[ -f "$ROOT_DIR/installer/smoke/init" ]] || {
  echo "ERROR: installer/smoke/init is missing" >&2
  exit 3
}

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS/bin" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/tmp" "$VM_ARTIFACT_DIR"
install -m 0755 "$BUSYBOX" "$ROOTFS/bin/busybox"
install -m 0755 "$ROOT_DIR/installer/smoke/init" "$ROOTFS/init"

for applet in sh mount cat grep ls poweroff reboot sleep echo dmesg uname; do
  ln -s busybox "$ROOTFS/bin/$applet"
done

# Normalize timestamps so identical inputs produce an identical cpio stream.
find "$ROOTFS" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

(
  cd "$ROOTFS"
  find . -print0 \
    | LC_ALL=C sort -z \
    | cpio --null --create --format=newc --owner=0:0 2>/dev/null \
    | gzip -n -9 > "$OUTPUT"
)

[[ -s "$OUTPUT" ]] || {
  echo "ERROR: smoke initramfs was not created" >&2
  exit 4
}

sha256sum "$OUTPUT" > "$OUTPUT.sha256"
echo "KERNEL_SMOKE_INITRAMFS = PASS"
echo "OUTPUT = $OUTPUT"
cat "$OUTPUT.sha256"
