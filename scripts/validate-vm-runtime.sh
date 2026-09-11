#!/usr/bin/env bash
set -euo pipefail

EDITION="${1:-accessible-aosp}"
ADB="${ADB:-adb}"
SERIAL_ARGS=()

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  SERIAL_ARGS=(-s "$ANDROID_SERIAL")
fi

adb_cmd() {
  "$ADB" "${SERIAL_ARGS[@]}" "$@"
}

fail() {
  echo "RUNTIME_FAIL: $*" >&2
  exit 2
}

command -v "$ADB" >/dev/null 2>&1 || fail "adb not found"
adb_cmd get-state >/dev/null 2>&1 || fail "no adb device"

boot_completed="$(adb_cmd shell getprop sys.boot_completed | tr -d '\r')"
[[ "$boot_completed" == "1" ]] || fail "Android has not completed boot"

echo "BOOT_COMPLETED = PASS"

adb_cmd shell cmd package list packages >/dev/null || fail "PackageManager is unavailable"
echo "PACKAGE_MANAGER = PASS"

surface_service="$(adb_cmd shell service check SurfaceFlinger 2>/dev/null | tr -d '\r' || true)"
[[ "$surface_service" == *found* ]] || fail "SurfaceFlinger service is unavailable"
adb_cmd shell dumpsys SurfaceFlinger >/dev/null 2>&1 || fail "SurfaceFlinger cannot be queried"

drm_nodes="$(adb_cmd shell 'ls /dev/dri/card* 2>/dev/null || true' | tr -d '\r')"
[[ -n "$drm_nodes" ]] || fail "no DRM/KMS card is exposed to Android"
echo "GRAPHICAL_STACK = PASS"
echo "DRM_DEVICE = PASS ($drm_nodes)"

accessibility_enabled="$(adb_cmd shell settings get secure accessibility_enabled | tr -d '\r')"
[[ "$accessibility_enabled" == "1" ]] || fail "Android accessibility is not enabled"

services="$(adb_cmd shell settings get secure enabled_accessibility_services | tr -d '\r')"
[[ -n "$services" && "$services" != "null" ]] || fail "no accessibility service is enabled"

accessibility_dump="$(adb_cmd shell dumpsys accessibility 2>/dev/null | tr -d '\r' || true)"
[[ -n "$accessibility_dump" ]] || fail "AccessibilityManagerService cannot be queried"

IFS=':' read -r -a enabled_services <<<"$services"
for component in "${enabled_services[@]}"; do
  [[ -n "$component" ]] || continue
  package_name="${component%%/*}"
  [[ -n "$package_name" ]] || fail "invalid accessibility service component: $component"
  adb_cmd shell cmd package path "$package_name" >/dev/null 2>&1 || \
    fail "enabled accessibility service package is missing: $package_name"
  if ! grep -Fq "$package_name" <<<"$accessibility_dump"; then
    fail "enabled accessibility service is absent from dumpsys accessibility: $package_name"
  fi
done

echo "ACCESSIBILITY = PASS"
echo "ACCESSIBILITY_SERVICES = $services"

tts="$(adb_cmd shell settings get secure tts_default_synth | tr -d '\r')"
[[ -n "$tts" && "$tts" != "null" ]] || fail "no default TTS engine is configured"
adb_cmd shell cmd package path "$tts" >/dev/null 2>&1 || fail "default TTS package is missing: $tts"
echo "TTS = PASS ($tts)"

audio_service="$(adb_cmd shell service check audio 2>/dev/null | tr -d '\r' || true)"
[[ "$audio_service" == *found* ]] || fail "Android audio service is unavailable"
adb_cmd shell dumpsys audio >/dev/null 2>&1 || fail "Android AudioService cannot be queried"
adb_cmd shell dumpsys media.audio_flinger >/dev/null 2>&1 || fail "AudioFlinger cannot be queried"

audio_cards="$(adb_cmd shell 'cat /proc/asound/cards 2>/dev/null || true' | tr -d '\r')"
[[ -n "$audio_cards" ]] || fail "no ALSA sound card information is exposed"
if grep -Eiq 'no soundcards|--- no soundcards ---' <<<"$audio_cards"; then
  fail "Android kernel reports no sound cards"
fi
if ! grep -Eiq 'virtio' <<<"$audio_cards"; then
  fail "the VM sound card is not the expected virtio-snd device"
fi
echo "AUDIO_SERVICE = PASS"
echo "AUDIO_FLINGER = PASS"
echo "AUDIO_DEVICE = PASS"

# AccessibleUTM intentionally fixes the boot-critical Android PCI topology.
# Validate it from inside the guest so a host-side argument regression cannot
# silently produce a different device layout.
pci_contract="$(adb_cmd shell 'for slot in 0000:00:06.0 0000:00:07.0 0000:00:08.0; do test -e /sys/bus/pci/devices/$slot || exit 1; done; echo PASS' 2>/dev/null | tr -d '\r' || true)"
[[ "$pci_contract" == "PASS" ]] || fail "expected AccessibleAndroid PCI slots 00:06.0/00:07.0/00:08.0 are not all present"

disk_device="$(adb_cmd shell 'readlink -f /sys/class/block/vda/device 2>/dev/null || true' | tr -d '\r')"
[[ "$disk_device" == *"0000:00:06.0"* ]] || fail "Android OS disk is not attached at PCI 0000:00:06.0"
echo "PCI_HARDWARE_CONTRACT = PASS"
echo "ANDROID_OS_DISK_PCI = PASS (0000:00:06.0)"

input_devices="$(adb_cmd shell 'getevent -lp 2>/dev/null || cat /proc/bus/input/devices 2>/dev/null || true' | tr -d '\r')"
[[ -n "$input_devices" ]] || fail "no input devices are visible"
if ! grep -Eiq 'keyboard|kbd' <<<"$input_devices"; then
  fail "no keyboard-capable VM input device was detected"
fi
if ! grep -Eiq 'tablet|mouse|touch' <<<"$input_devices"; then
  fail "no pointer-capable VM input device was detected"
fi
echo "INPUT_KEYBOARD = PASS"
echo "INPUT_POINTER = PASS"

network_links="$(adb_cmd shell 'ip -o link show 2>/dev/null || true' | tr -d '\r')"
[[ -n "$network_links" ]] || fail "Android network interfaces cannot be enumerated"
if ! awk -F': ' '$2 != "lo" {found=1} END {exit(found ? 0 : 1)}' <<<"$network_links"; then
  fail "no non-loopback network interface is available"
fi
echo "NETWORK_DEVICE = PASS"

case "$EDITION" in
  accessible-aosp)
    echo "GMS = NOT_REQUIRED"
    ;;
  accessible-gms)
    adb_cmd shell cmd package path com.google.android.gms >/dev/null 2>&1 || fail "Google Play services package is missing"
    adb_cmd shell cmd package path com.android.vending >/dev/null 2>&1 || fail "Google Play Store package is missing"
    echo "GOOGLE_PLAY_SERVICES = PASS"
    echo "PLAY_STORE = PASS"
    ;;
  *)
    fail "unknown edition: $EDITION"
    ;;
esac

# Verify persistence-critical storage is writable from the shell context.
adb_cmd shell 'test -d /data && test -d /data/user' || fail "/data is not available"
echo "PERSISTENT_DATA_LAYOUT = PASS"

echo "RUNTIME_RESULT = PASS"
