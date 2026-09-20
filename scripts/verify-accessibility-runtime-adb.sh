#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

ADB="${ADB:-adb}"
ADB_SERIAL="${ADB_SERIAL:-}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-180}"
ACCESSIBILITY_BIND_TIMEOUT_SECONDS="${ACCESSIBILITY_BIND_TIMEOUT_SECONDS:-30}"
TTS_SMOKE_TIMEOUT_SECONDS="${TTS_SMOKE_TIMEOUT_SECONDS:-45}"

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
  awk -v start="$start" -v stop="$stop" '
    index($0, start) {
      inside = 1
    }
    inside && index($0, stop) {
      exit
    }
    inside {
      print
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

bootstrap_path="$(run_shell pm path "$ACCESSIBILITY_BOOTSTRAP_PACKAGE" 2>/dev/null | clean_cr || true)"
[[ "$bootstrap_path" == package:* ]] || fail "Accessibility bootstrap package is not installed: $ACCESSIBILITY_BOOTSTRAP_PACKAGE"

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

audio_policy_dump="$(run_shell dumpsys media.audio_policy 2>/dev/null | clean_cr || true)"
[[ -n "$audio_policy_dump" ]] || fail "AudioPolicy dump is empty"

input_dump="$(run_shell dumpsys input 2>/dev/null | clean_cr || true)"
[[ -n "$input_dump" ]] || fail "InputManager dump is empty"

surface_flinger_dump="$(run_shell dumpsys SurfaceFlinger 2>/dev/null | clean_cr || true)"
[[ -n "$surface_flinger_dump" ]] || fail "SurfaceFlinger dump is empty"

display_dump="$(run_shell dumpsys display 2>/dev/null | clean_cr || true)"
[[ -n "$display_dump" ]] || fail "DisplayManager dump is empty"

# Exercise the configured offline engine instead of accepting package/settings
# presence as proof of speech. The privileged bootstrap receiver synthesizes
# one English and one French utterance and reports completion through logcat.
run_shell logcat -c >/dev/null 2>&1 || true
broadcast_output="$(run_shell am broadcast \
  -a "$ACCESSIBILITY_TTS_SMOKE_ACTION" \
  -n "$ACCESSIBILITY_TTS_SMOKE_COMPONENT" 2>&1 | clean_cr || true)"
grep -Fq "Broadcast completed" <<<"$broadcast_output" || {
  printf '%s\n' "$broadcast_output" >&2
  fail "TTS smoke broadcast did not complete"
}

tts_deadline=$((SECONDS + TTS_SMOKE_TIMEOUT_SECONDS))
tts_log=""
while true; do
  tts_log="$(run_shell logcat -d -s AccessibleTtsSmoke:V 2>/dev/null | clean_cr || true)"
  if grep -Fq "ACCESSIBLE_TTS_SMOKE=PASS" <<<"$tts_log"; then
    break
  fi
  if grep -Fq "ACCESSIBLE_TTS_SMOKE=FAIL" <<<"$tts_log"; then
    printf '%s\n' "$tts_log" >&2
    fail "offline TTS smoke test reported failure"
  fi
  if (( SECONDS >= tts_deadline )); then
    printf '%s\n' "$tts_log" >&2
    fail "offline TTS smoke test did not finish within ${TTS_SMOKE_TIMEOUT_SECONDS}s"
  fi
  sleep 1
done

grep -Fq "TTS_SMOKE_EN_US=PASS" <<<"$tts_log" || fail "English TTS smoke did not complete"
grep -Fq "TTS_SMOKE_FR_FR=PASS" <<<"$tts_log" || fail "French TTS smoke did not complete"

echo "ANDROID_BOOT_COMPLETED = PASS"
echo "TALKBACK_PACKAGE = PASS"
echo "TALKBACK_SERVICE_REGISTERED = PASS"
echo "TALKBACK_ENABLED = PASS"
echo "TALKBACK_BOUND = PASS"
echo "ESPEAK_PACKAGE = PASS"
echo "OFFLINE_TTS_DEFAULT = PASS"
echo "AUDIO_SERVICE = PASS"
echo "AUDIO_FLINGER = PASS"
echo "AUDIO_POLICY = PASS"
echo "INPUT_MANAGER = PASS"
echo "SURFACE_FLINGER = PASS"
echo "DISPLAY_MANAGER = PASS"
echo "TTS_SYNTHESIS_EN_US = PASS"
echo "TTS_SYNTHESIS_FR_FR = PASS"
echo "ACCESSIBILITY_RUNTIME = PASS"
