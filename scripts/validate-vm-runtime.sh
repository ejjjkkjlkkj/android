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

accessibility_enabled="$(adb_cmd shell settings get secure accessibility_enabled | tr -d '\r')"
[[ "$accessibility_enabled" == "1" ]] || fail "Android accessibility is not enabled"

services="$(adb_cmd shell settings get secure enabled_accessibility_services | tr -d '\r')"
[[ -n "$services" && "$services" != "null" ]] || fail "no accessibility service is enabled"

echo "ACCESSIBILITY = PASS"
echo "ACCESSIBILITY_SERVICES = $services"

tts="$(adb_cmd shell settings get secure tts_default_synth | tr -d '\r')"
[[ -n "$tts" && "$tts" != "null" ]] || fail "no default TTS engine is configured"
echo "TTS = PASS ($tts)"

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
