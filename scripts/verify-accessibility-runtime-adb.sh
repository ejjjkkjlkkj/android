#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

ADB="${ADB:-adb}"
ADB_SERIAL="${ADB_SERIAL:-}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-180}"
ACCESSIBILITY_CONNECT_TIMEOUT_SECONDS="${ACCESSIBILITY_CONNECT_TIMEOUT_SECONDS:-30}"

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

extract_state_block() {
  local heading="$1"
  awk -v heading="$heading" '
    index($0, heading) {
      found = 1
      print
      if (index($0, "}")) {
        exit
      }
      next
    }
    found {
      print
      if (index($0, "}")) {
        exit
      }
    }
  '
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

# Settings alone are not proof that an AccessibilityService is connected. Android
# keeps separate enabled, binding, bound and crashed service state. Wait briefly
# for AccessibilityManager to finish binding TalkBack, then require a live
# ActivityManager service record and reject binding/crashed states.
talkback_class="${TALKBACK_SERVICE#*/}"
connect_deadline=$((SECONDS + ACCESSIBILITY_CONNECT_TIMEOUT_SECONDS))
talkback_connected=0
last_accessibility_dump=""
last_activity_services_dump=""

while true; do
  last_accessibility_dump="$(run_shell dumpsys accessibility 2>/dev/null | clean_cr || true)"
  enabled_block="$(printf '%s\n' "$last_accessibility_dump" | extract_state_block " Enabled services:{")"
  binding_block="$(printf '%s\n' "$last_accessibility_dump" | extract_state_block " Binding services:{")"
  crashed_block="$(printf '%s\n' "$last_accessibility_dump" | extract_state_block " Crashed services:{")"
  last_activity_services_dump="$(
    run_shell dumpsys activity services "$TALKBACK_PACKAGE" 2>/dev/null | clean_cr || true
  )"

  if grep -Fq "$TALKBACK_SERVICE" <<<"$enabled_block" \
      && ! grep -Fq "$TALKBACK_SERVICE" <<<"$binding_block" \
      && ! grep -Fq "$TALKBACK_SERVICE" <<<"$crashed_block" \
      && grep -Fq "$talkback_class" <<<"$last_activity_services_dump"; then
    talkback_connected=1
    break
  fi

  if (( SECONDS >= connect_deadline )); then
    break
  fi
  sleep 1
done

if [[ "$talkback_connected" != "1" ]]; then
  echo "AccessibilityManager state:" >&2
  printf '%s\n' "$last_accessibility_dump" >&2
  echo "ActivityManager TalkBack service state:" >&2
  printf '%s\n' "$last_activity_services_dump" >&2
  fail "TalkBack is enabled but not stably connected to AccessibilityManager"
fi

audio_dump="$(run_shell dumpsys audio 2>/dev/null | clean_cr || true)"
[[ -n "$audio_dump" ]] || fail "AudioService dump is empty"

audio_flinger_dump="$(run_shell dumpsys media.audio_flinger 2>/dev/null | clean_cr || true)"
[[ -n "$audio_flinger_dump" ]] || fail "AudioFlinger dump is empty"

audio_policy_dump="$(run_shell dumpsys media.audio_policy 2>/dev/null | clean_cr || true)"
[[ -n "$audio_policy_dump" ]] || fail "AudioPolicy dump is empty"

input_dump="$(run_shell dumpsys input 2>/dev/null | clean_cr || true)"
[[ -n "$input_dump" ]] || fail "InputManager dump is empty"

echo "ANDROID_BOOT_COMPLETED = PASS"
echo "TALKBACK_PACKAGE = PASS"
echo "TALKBACK_SERVICE_REGISTERED = PASS"
echo "TALKBACK_ENABLED = PASS"
echo "TALKBACK_CONNECTED = PASS"
echo "ESPEAK_PACKAGE = PASS"
echo "OFFLINE_TTS_DEFAULT = PASS"
echo "AUDIO_SERVICE = PASS"
echo "AUDIO_FLINGER = PASS"
echo "AUDIO_POLICY = PASS"
echo "INPUT_MANAGER = PASS"
echo "ACCESSIBILITY_RUNTIME = PASS"
