#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/vmware.env"

PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
PREINSTALLED_DIR="$VM_ARTIFACT_DIR/preinstalled"
SOURCE_VMDK="$PREINSTALLED_DIR/AccessibleAndroid-17-${PRODUCT}-x86_64.vmdk"
BUNDLE_DIR="$VM_ARTIFACT_DIR/vmware/AccessibleAndroid-17-${PRODUCT}-VMware"
BUNDLE_VMDK="$BUNDLE_DIR/AccessibleAndroid-17.vmdk"
VMX="$BUNDLE_DIR/AccessibleAndroid-17.vmx"

[[ -s "$SOURCE_VMDK" ]] || {
  echo "ERROR: VMDK not found: $SOURCE_VMDK" >&2
  echo "Run scripts/build-preinstalled-disk.sh first." >&2
  exit 2
}

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
cp "$SOURCE_VMDK" "$BUNDLE_VMDK"

cat > "$VMX" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "AccessibleAndroid 17"
guestOS = "$VMWARE_GUEST_OS"
firmware = "$VMWARE_FIRMWARE"

numvcpus = "$VMWARE_CPUS"
memsize = "$VMWARE_MEMORY_MIB"
vhv.enable = "TRUE"

scsi0.present = "TRUE"
scsi0.virtualDev = "$VMWARE_DISK_CONTROLLER"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$(basename "$BUNDLE_VMDK")"

ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "$VMWARE_NETWORK_ADAPTER"
ethernet0.addressType = "generated"

svga.present = "TRUE"
svga.autodetect = "TRUE"
mks.enable3d = "TRUE"

sound.present = "TRUE"
sound.autodetect = "TRUE"
sound.virtualDev = "$VMWARE_AUDIO_PRIMARY"

usb.present = "TRUE"
ehci.present = "TRUE"
usb_xhci.present = "TRUE"

floppy0.present = "FALSE"

serial0.present = "TRUE"
serial0.fileType = "file"
serial0.fileName = "serial.log"
serial0.tryNoRxLoss = "TRUE"

tools.syncTime = "FALSE"
EOF

cat > "$BUNDLE_DIR/README.txt" <<'EOF'
AccessibleAndroid 17 - VMware Workstation bundle

Open AccessibleAndroid-17.vmx in VMware Workstation.

Reference hardware:
- UEFI firmware
- 6 vCPU
- 8192 MiB RAM
- VMware PVSCSI disk
- VMXNET3 networking
- VMware SVGA graphics / vmwgfx
- HDA audio
- xHCI USB
- serial boot log written to serial.log

Release validation is not complete until scripts/verify-vmware-runtime-adb.sh
passes against the running guest and the accessibility speech test is audible.
EOF

(
  cd "$BUNDLE_DIR"
  sha256sum "$(basename "$BUNDLE_VMDK")" "$(basename "$VMX")" README.txt > SHA256SUMS
)

echo "VMWARE_BUNDLE = PASS"
echo "VMX = $VMX"
echo "VMDK = $BUNDLE_VMDK"
cat "$BUNDLE_DIR/SHA256SUMS"
