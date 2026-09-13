#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"

ISO="${SMOKE_ISO:-$VM_ARTIFACT_DIR/AccessibleAndroid-17-kernel-smoke-x86_64.iso}"
QEMU="${QEMU:-$(command -v qemu-system-x86_64 || true)}"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-60}"
TEST_MODE="${TEST_MODE:-all}"

[[ -n "$QEMU" && -x "$QEMU" ]] || {
  echo "ERROR: qemu-system-x86_64 is required" >&2
  exit 2
}
[[ -s "$ISO" ]] || {
  echo "ERROR: smoke ISO not found at $ISO" >&2
  echo "Run scripts/package-kernel-smoke-iso.sh first." >&2
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
  local log="$BUILD_LOG_DIR/kernel-smoke-${mode}.log"
  local -a firmware_args=()

  if [[ "$mode" == "uefi" ]]; then
    local ovmf
    ovmf="$(find_ovmf)" || {
      echo "ERROR: OVMF firmware not found for UEFI test" >&2
      return 5
    }
    firmware_args=(-bios "$ovmf")
  fi

  echo "==> QEMU kernel smoke test: $mode"
  rm -f "$log"

  set +e
  timeout --signal=TERM "$BOOT_TIMEOUT_SECONDS" \
    "$QEMU" \
      -machine "q35,accel=$QEMU_ACCEL" \
      -cpu max \
      -m 1024 \
      -smp 2 \
      "${firmware_args[@]}" \
      -cdrom "$ISO" \
      -boot order=d \
      -device virtio-rng-pci \
      -display none \
      -serial stdio \
      -monitor none \
      -no-reboot \
      >"$log" 2>&1
  local qemu_status=$?
  set -e

  if ! grep -Fq 'ACCESSIBLE_ANDROID_KERNEL_BOOT=PASS' "$log"; then
    echo "ERROR: $mode boot did not reach the smoke initramfs marker (QEMU status $qemu_status)" >&2
    tail -n 120 "$log" >&2 || true
    return 6
  fi

  grep -Fq 'SMOKE_CONSOLE=READY' "$log" || {
    echo "ERROR: $mode boot reached init but serial console did not become ready" >&2
    tail -n 120 "$log" >&2 || true
    return 7
  }

  echo "KERNEL_SMOKE_${mode^^} = PASS"
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

echo "KERNEL_SMOKE_QEMU = PASS"
