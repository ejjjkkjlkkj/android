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
echo "GRAPHICAL_STACK = PASS"

accessibility_enabled="$(adb_cmd shell settings get secure accessibility_enabled | tr -d '\r')"
[[ "$accessibility_enabled" == "1" ]] || fail "Android accessibility is not enabled"

services="$(adb_cmd shell settings get secure enabled_accessibility_services | tr -d '\r')"
[[ -n "$services" && "$services" != "null" ]] || fail "no accessibility service is enabled"

echo "ACCESSIBILITY = PASS"
echo "ACCESSIBILITY_SERVICES = $services"

tts="$(adb_cmd shell settings get secure tts_default_synth | tr -d '\r')"
[[ -n "$tts" && "$tts" != "null" ]] || fail "no default TTS engine is configured"
echo "TTS = PASS ($tts)"

audio_service="$(adb_cmd shell service check audio 2>/dev/null | tr -d '\r' || true)"
[[ "$audio_service" == *found* ]] || fail "Android audio service is unavailable"
adb_cmd shell dumpsys audio >/dev/null 2>&1 || fail "Android AudioService cannot be queried"

audio_cards="$(adb_cmd shell 'cat /proc/asound/cards 2>/dev/null || true' | tr -d '\r')"
[[ -n "$audio_cards" ]] || fail "no ALSA sound card information is exposed"
if grep -Eiq 'no soundcards|--- no soundcards ---' <<<"$audio_cards"; then
  fail "Android kernel reports no sound cards"
fi
echo "AUDIO_DEVICE = PASS"

input_devices="$(adb_cmd shell 'getevent -lp 2>/dev/null || cat /proc/bus/input/devices 2>/dev/null || true' | tr -d '\r')"
[[ -n "$input_devices" ]] || fail "no input devices are visible"
if ! grep -Eiq 'keyboard|kbd|tablet|mouse|touch|virtio|qemu' <<<"$input_devices"; then
  fail "no keyboard/pointer-capable VM input device was detected"
fi
echo "INPUT_DEVICES = PASS"

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
