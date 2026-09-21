#!/usr/bin/env bash
set -euo pipefail

ADB="${ADB:-adb}"
SERIAL="${ANDROID_SERIAL:-}"

adb_cmd() {
  if [[ -n "$SERIAL" ]]; then
    "$ADB" -s "$SERIAL" "$@"
  else
    "$ADB" "$@"
  fi
}

adb_cmd wait-for-device
# The command is intentionally expanded by the Android guest shell, not by the host.
# shellcheck disable=SC2016
adb_cmd shell 'until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done'

check() {
  local label="$1"
  shift
  if adb_cmd shell "$@" >/dev/null 2>&1; then
    echo "$label = PASS"
  else
    echo "$label = FAIL" >&2
    return 1
  fi
}

# shellcheck disable=SC2016
check VMWARE_BOOT_COMPLETE 'test "$(getprop sys.boot_completed)" = "1"'
check VMWARE_DRM_DEVICE 'test -e /dev/dri/card0'
check VMWARE_AUDIO_DEVICE 'test -d /dev/snd && ls /dev/snd/* >/dev/null 2>&1'
check VMWARE_INPUT_DEVICES 'test -r /proc/bus/input/devices'
check VMWARE_NETWORK_INTERFACE 'ip link | grep -Eq "^[0-9]+: (eth|en)[^:]*:"'
check VMWARE_DATA_PERSISTENCE 'test -d /data'

# Kernel driver evidence: built-ins appear in /sys even when lsmod is empty.
# shellcheck disable=SC2016
adb_cmd shell 'for d in vmwgfx vmxnet3 vmw_pvscsi vmw_vmci snd_hda_intel snd_ens1371 xhci_hcd; do
  if find /sys/bus -type l -path "*/drivers/$d" -print -quit 2>/dev/null | grep -q . || grep -qw "$d" /proc/modules 2>/dev/null; then
    echo "VMWARE_DRIVER_$d=PASS"
  else
    echo "VMWARE_DRIVER_$d=NOT_OBSERVED"
  fi
done'

adb_cmd shell 'settings get secure enabled_accessibility_services' | grep -vqE '^(null|)$' || {
  echo "VMWARE_ACCESSIBILITY_SERVICE = FAIL" >&2
  exit 6
}
echo "VMWARE_ACCESSIBILITY_SERVICE = PASS"

adb_cmd shell 'settings get secure tts_default_synth' | grep -vqE '^(null|)$' || {
  echo "VMWARE_TTS_ENGINE = FAIL" >&2
  exit 7
}
echo "VMWARE_TTS_ENGINE = PASS"

echo "VMWARE_RUNTIME_GATE = PASS"
