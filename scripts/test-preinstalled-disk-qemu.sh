#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/vm.env"

PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
DISK="${PREINSTALLED_DISK:-$VM_ARTIFACT_DIR/preinstalled/AccessibleAndroid-17-${PRODUCT}-x86_64.qcow2}"
QEMU="${QEMU:-$(command -v qemu-system-x86_64 || true)}"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-300}"
TEST_MODE="${TEST_MODE:-all}"
FRAMEWORK_MARKER='ACCESSIBLE_ANDROID_FRAMEWORK_BOOT=PASS'
POST_FS_MARKER='ACCESSIBLE_ANDROID_POST_FS_DATA=PASS'

[[ -n "$QEMU" && -x "$QEMU" ]] || {
  echo "ERROR: qemu-system-x86_64 is required" >&2
  exit 2
}
[[ -s "$DISK" ]] || {
  echo "ERROR: preinstalled QCOW2 disk not found at $DISK" >&2
  echo "Run scripts/build-preinstalled-disk.sh first." >&2
  exit 3
}
command -v timeout >/dev/null 2>&1 || {
  echo "ERROR: timeout is required" >&2
  exit 4
}

mkdir -p "$BUILD_LOG_DIR"

find_ovmf() {
  local candidate
  for candidate in \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

run_boot_test() {
  local mode="$1"
  local log="$BUILD_LOG_DIR/preinstalled-android-${mode}.log"
  local -a firmware_args=()

  if [[ "$mode" == "uefi" ]]; then
    local ovmf
    ovmf="$(find_ovmf)" || {
      echo "ERROR: OVMF firmware not found for UEFI test" >&2
      return 5
    }
    firmware_args=(-bios "$ovmf")
  fi

  echo "==> QEMU preinstalled Android test: $mode"
  rm -f "$log"

  set +e
  timeout --signal=TERM "$BOOT_TIMEOUT_SECONDS" \
    "$QEMU" \
      -machine "$VM_MACHINE,accel=$QEMU_ACCEL" \
      -cpu max \
      -m "$VM_MEMORY_MIB" \
      -smp "$VM_CPUS" \
      "${firmware_args[@]}" \
      -drive "if=none,id=$VM_OS_DISK_ID,file=$DISK,format=qcow2,cache=writeback" \
      -device "virtio-blk-pci,drive=$VM_OS_DISK_ID,bus=pcie.0,addr=$VM_OS_DISK_PCI_ADDR,bootindex=1" \
      -device 'virtio-rng-pci,bus=pcie.0,addr=0x7' \
      -netdev user,id=net0 \
      -device 'virtio-net-pci,netdev=net0,bus=pcie.0,addr=0x8' \
      -boot order=c \
      -display none \
      -serial stdio \
      -monitor none \
      -no-reboot \
      >"$log" 2>&1
  local qemu_status=$?
  set -e

  if ! grep -Fq "$POST_FS_MARKER" "$log"; then
    echo "ERROR: $mode boot never reached Android post-fs-data (QEMU status $qemu_status)" >&2
    tail -n 200 "$log" >&2 || true
    return 6
  fi

  if ! grep -Fq "$FRAMEWORK_MARKER" "$log"; then
    echo "ERROR: $mode boot reached Android userspace but not sys.boot_completed=1 (QEMU status $qemu_status)" >&2
    tail -n 200 "$log" >&2 || true
    return 7
  fi

  echo "PREINSTALLED_ANDROID_${mode^^} = PASS"
  echo "FRAMEWORK_BOOT = PASS"
  echo "LOG = $log"
}

case "$TEST_MODE" in
  bios)
    run_boot_test bios
    ;;
  uefi)
    run_boot_test uefi
    ;;
  all)
    run_boot_test bios
    run_boot_test uefi
    ;;
  *)
    echo "ERROR: TEST_MODE must be bios, uefi or all" >&2
    exit 8
    ;;
esac

echo "PREINSTALLED_ANDROID_QEMU = PASS"
