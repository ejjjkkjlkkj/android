#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

ADB="${ADB:-adb}"
ADB_SERIAL="${ADB_SERIAL:-}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-180}"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

command -v "$ADB" >/dev/null 2>&1 || fail "adb was not found: $ADB"

adb_args=()
if [[ -n "$ADB_SERIAL" ]]; then
  adb_args=(-s "$ADB_SERIAL")
fi

run_adb() {
  "$ADB" "${adb_args[@]}" "$@"
}

run_shell() {
  run_adb shell "$@"
}

clean_cr() {
  tr -d '\r'
}

echo "Waiting for Android ADB device..."
run_adb start-server >/dev/null
run_adb wait-for-device

deadline=$((SECONDS + BOOT_TIMEOUT_SECONDS))
while true; do
  boot_completed="$(run_shell getprop sys.boot_completed 2>/dev/null | clean_cr || true)"
  if [[ "$boot_completed" == "1" ]]; then
    break
  fi
  if (( SECONDS >= deadline )); then
    fail "sys.boot_completed did not become 1 within ${BOOT_TIMEOUT_SECONDS}s"
  fi
  sleep 2
done

talkback_path="$(run_shell pm path "$TALKBACK_PACKAGE" 2>/dev/null | clean_cr || true)"
[[ "$talkback_path" == package:* ]] || fail "TalkBack package is not installed: $TALKBACK_PACKAGE"

espeak_path="$(run_shell pm path "$ESPEAK_PACKAGE" 2>/dev/null | clean_cr || true)"
[[ "$espeak_path" == package:* ]] || fail "eSpeak TTS package is not installed: $ESPEAK_PACKAGE"

accessibility_enabled="$(run_shell settings get secure accessibility_enabled | clean_cr)"
[[ "$accessibility_enabled" == "1" ]] || fail "accessibility_enabled=$accessibility_enabled (expected 1)"

enabled_services="$(run_shell settings get secure enabled_accessibility_services | clean_cr)"
case ":${enabled_services}:" in
  *":${TALKBACK_SERVICE}:"*) ;;
  *) fail "TalkBack service is not enabled: $TALKBACK_SERVICE; enabled=$enabled_services" ;;
esac

default_tts="$(run_shell settings get secure tts_default_synth | clean_cr)"
[[ "$default_tts" == "$ESPEAK_PACKAGE" ]] || fail "tts_default_synth=$default_tts (expected $ESPEAK_PACKAGE)"

talkback_dump="$(run_shell dumpsys package "$TALKBACK_PACKAGE" 2>/dev/null | clean_cr || true)"
grep -Fq "TalkBackService" <<<"$talkback_dump" || fail "TalkBackService is not registered in PackageManager"

accessibility_dump="$(run_shell dumpsys accessibility 2>/dev/null | clean_cr || true)"
grep -Fq "$TALKBACK_PACKAGE" <<<"$accessibility_dump" || fail "AccessibilityManager does not report TalkBack"

audio_dump="$(run_shell dumpsys audio 2>/dev/null | clean_cr || true)"
[[ -n "$audio_dump" ]] || fail "AudioService dump is empty"

echo "ANDROID_BOOT_COMPLETED = PASS"
echo "TALKBACK_PACKAGE = PASS"
echo "TALKBACK_SERVICE_REGISTERED = PASS"
echo "TALKBACK_ENABLED = PASS"
echo "ESPEAK_PACKAGE = PASS"
echo "OFFLINE_TTS_DEFAULT = PASS"
echo "AUDIO_SERVICE = PASS"
echo "ACCESSIBILITY_RUNTIME = PASS"
