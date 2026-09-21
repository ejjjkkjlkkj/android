#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"

SRC_FRAGMENT="$ROOT_DIR/kernel/vmware_x86_64.fragment"
TARGET_FRAGMENT="$KERNEL_SRC_DIR/common-modules/virtual-device/linux_distro.fragment"
MARK_BEGIN="# BEGIN ACCESSIBLEANDROID VMWARE PROFILE"
MARK_END="# END ACCESSIBLEANDROID VMWARE PROFILE"

[[ -s "$SRC_FRAGMENT" ]] || {
  echo "ERROR: VMware kernel fragment not found: $SRC_FRAGMENT" >&2
  exit 2
}
[[ -f "$TARGET_FRAGMENT" ]] || {
  echo "ERROR: upstream linux_distro.fragment not found: $TARGET_FRAGMENT" >&2
  echo "Run scripts/sync-kernel.sh first." >&2
  exit 3
}

python3 - "$TARGET_FRAGMENT" "$SRC_FRAGMENT" "$MARK_BEGIN" "$MARK_END" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1])
source = Path(sys.argv[2])
begin = sys.argv[3]
end = sys.argv[4]

text = target.read_text(encoding="utf-8")
if begin in text:
    prefix, rest = text.split(begin, 1)
    if end not in rest:
        raise SystemExit("ERROR: malformed existing AccessibleAndroid VMware profile block")
    _, suffix = rest.split(end, 1)
    text = prefix.rstrip() + "\n" + suffix.lstrip("\n")

payload = source.read_text(encoding="utf-8").rstrip()
target.write_text(text.rstrip() + "\n\n" + begin + "\n" + payload + "\n" + end + "\n", encoding="utf-8")
PY

for symbol in   CONFIG_SCSI_VMW_PVSCSI=y   CONFIG_DRM_VMWGFX=y   CONFIG_VMXNET3=y   CONFIG_VMWARE_VMCI=y   CONFIG_VMWARE_VMCI_VSOCKETS=y   CONFIG_SND_HDA_INTEL=y   CONFIG_SND_ENS1371=y   CONFIG_USB_XHCI_HCD=y   CONFIG_USB_HID=y; do
  grep -Fqx "$symbol" "$TARGET_FRAGMENT" || {
    echo "ERROR: VMware kernel symbol was not applied: $symbol" >&2
    exit 4
  }
done

echo "VMWARE_KERNEL_PROFILE = PASS"
echo "TARGET_FRAGMENT = $TARGET_FRAGMENT"
