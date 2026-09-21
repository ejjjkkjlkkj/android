#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/vmware.env"

FRAGMENT="$ROOT_DIR/kernel/vmware_x86_64.fragment"

[[ -s "$FRAGMENT" ]] || {
  echo "ERROR: missing VMware kernel fragment: $FRAGMENT" >&2
  exit 2
}

required_symbols=(
  CONFIG_HYPERVISOR_GUEST
  CONFIG_SCSI_VMW_PVSCSI
  CONFIG_SATA_AHCI
  CONFIG_BLK_DEV_NVME
  CONFIG_DRM_VMWGFX
  CONFIG_VMXNET3
  CONFIG_E1000
  CONFIG_E1000E
  CONFIG_VMWARE_VMCI
  CONFIG_VSOCKETS
  CONFIG_VMWARE_VMCI_VSOCKETS
  CONFIG_INPUT_EVDEV
  CONFIG_SERIO_I8042
  CONFIG_KEYBOARD_ATKBD
  CONFIG_MOUSE_PS2
  CONFIG_HID_GENERIC
  CONFIG_USB_XHCI_HCD
  CONFIG_USB_HID
  CONFIG_SND_HDA_INTEL
  CONFIG_SND_ENS1371
  CONFIG_BLK_DEV_SR
  CONFIG_ISO9660_FS
)

for symbol in "${required_symbols[@]}"; do
  grep -Eq "^${symbol}=(y|m)$" "$FRAGMENT" || {
    echo "ERROR: VMware driver contract missing $symbol" >&2
    exit 3
  }
done

# Build-time verification is optional here because CI lint does not download the
# Android kernel. When a synchronized kernel tree exists, verify the profile has
# actually been injected into the upstream build fragment.
UPSTREAM_FRAGMENT="$KERNEL_SRC_DIR/common-modules/virtual-device/linux_distro.fragment"
if [[ -f "$UPSTREAM_FRAGMENT" ]]; then
  for symbol in "${required_symbols[@]}"; do
    expected="$(grep -E "^${symbol}=(y|m)$" "$FRAGMENT" | tail -n 1)"
    grep -Fqx "$expected" "$UPSTREAM_FRAGMENT" || {
      echo "ERROR: synchronized kernel tree does not contain $expected" >&2
      exit 4
    }
  done
  echo "VMWARE_SYNCED_KERNEL_PROFILE = PASS"
fi

for value in   "$VMWARE_DISK_CONTROLLER"   "$VMWARE_NETWORK_ADAPTER"   "$VMWARE_GRAPHICS_ADAPTER"   "$VMWARE_AUDIO_PRIMARY"   "$VMWARE_USB_CONTROLLER"; do
  [[ -n "$value" ]] || {
    echo "ERROR: empty VMware hardware contract value" >&2
    exit 5
  }
done

echo "VMWARE_DRIVER_CONTRACT = PASS"
echo "STORAGE = PVSCSI + AHCI + NVMe"
echo "NETWORK = VMXNET3 + E1000/E1000E"
echo "GRAPHICS = VMWGFX/DRM"
echo "AUDIO = HDA + ES1371"
echo "INPUT_USB = i8042 + HID + xHCI"
echo "HOST_GUEST = VMCI + VSOCK"
