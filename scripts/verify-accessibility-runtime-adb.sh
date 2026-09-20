#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

ADB="${ADB:-adb}"
ADB_SERIAL="${ADB_SERIAL:-}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-180}"
ACCESSIBILITY_BIND_TIMEOUT_SECONDS="${ACCESSIBILITY_BIND_TIMEOUT_SECONDS:-30}"

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

extract_accessibility_section() {
  local start="$1"
  local stop="$2"
  sed -n "/$start/,/$stop/p"
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

# An enabled secure setting is not enough: AccessibilityManagerService keeps a
# separate mBoundServices list. Wait briefly for the framework to bind TalkBack
# and require the component to appear specifically in the "Bound services"
# section. This rejects enabled-but-not-connected and crashed states.
bind_deadline=$((SECONDS + ACCESSIBILITY_BIND_TIMEOUT_SECONDS))
accessibility_dump=""
bound_services=""
while true; do
  accessibility_dump="$(run_shell dumpsys accessibility 2>/dev/null | clean_cr || true)"
  [[ -n "$accessibility_dump" ]] || fail "AccessibilityManager dump is empty"

  bound_services="$(printf '%s\n' "$accessibility_dump" | extract_accessibility_section 'Bound services:{' 'Enabled services:{')"
  if grep -Fq "$TALKBACK_SERVICE" <<<"$bound_services"; then
    break
  fi

  if (( SECONDS >= bind_deadline )); then
    binding_services="$(printf '%s\n' "$accessibility_dump" | extract_accessibility_section 'Binding services:{' 'Crashed services:{')"
    crashed_services="$(printf '%s\n' "$accessibility_dump" | extract_accessibility_section 'Crashed services:{' 'Client list info:{')"
    echo "ACCESSIBILITY_BOUND_SERVICES_BEGIN" >&2
    printf '%s\n' "$bound_services" >&2
    echo "ACCESSIBILITY_BOUND_SERVICES_END" >&2
    echo "ACCESSIBILITY_BINDING_SERVICES_BEGIN" >&2
    printf '%s\n' "$binding_services" >&2
    echo "ACCESSIBILITY_BINDING_SERVICES_END" >&2
    echo "ACCESSIBILITY_CRASHED_SERVICES_BEGIN" >&2
    printf '%s\n' "$crashed_services" >&2
    echo "ACCESSIBILITY_CRASHED_SERVICES_END" >&2
    fail "TalkBack is enabled but not bound to AccessibilityManagerService: $TALKBACK_SERVICE"
  fi
  sleep 1
done

audio_dump="$(run_shell dumpsys audio 2>/dev/null | clean_cr || true)"
[[ -n "$audio_dump" ]] || fail "AudioService dump is empty"

audio_flinger_dump="$(run_shell dumpsys media.audio_flinger 2>/dev/null | clean_cr || true)"
[[ -n "$audio_flinger_dump" ]] || fail "AudioFlinger dump is empty"

echo "ANDROID_BOOT_COMPLETED = PASS"
echo "TALKBACK_PACKAGE = PASS"
echo "TALKBACK_SERVICE_REGISTERED = PASS"
echo "TALKBACK_ENABLED = PASS"
echo "TALKBACK_BOUND = PASS"
echo "ESPEAK_PACKAGE = PASS"
echo "OFFLINE_TTS_DEFAULT = PASS"
echo "AUDIO_SERVICE = PASS"
echo "AUDIO_FLINGER = PASS"
echo "ACCESSIBILITY_RUNTIME = PASS"
