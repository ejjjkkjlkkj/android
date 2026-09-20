#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT_DIR/scripts/verify-accessibility-runtime-adb.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MOCK_ADB="$TMP_DIR/adb"

cat > "$MOCK_ADB" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  start-server|wait-for-device)
    exit 0
    ;;
  shell)
    shift
    ;;
  *)
    echo "unexpected adb command: $*" >&2
    exit 90
    ;;
esac

cmd="$*"
talkback_service='com.android.talkback/com.google.android.marvin.talkback.TalkBackService'

case "$cmd" in
  'getprop sys.boot_completed')
    echo 1
    ;;
  'pm path com.android.talkback')
    echo 'package:/system/priv-app/AccessibleTalkBack/AccessibleTalkBack.apk'
    ;;
  'pm path com.reecedunn.espeak')
    echo 'package:/system/priv-app/AccessibleEspeakTts/AccessibleEspeakTts.apk'
    ;;
  'pm path org.accessibledroid.bootstrap')
    echo 'package:/system/priv-app/AccessibilityBootstrap/AccessibilityBootstrap.apk'
    ;;
  'settings get secure accessibility_enabled')
    if [[ "${MOCK_CASE:-pass}" == 'disabled' ]]; then
      echo 0
    else
      echo 1
    fi
    ;;
  'settings get secure enabled_accessibility_services')
    echo "$talkback_service"
    ;;
  'settings get secure tts_default_synth')
    echo 'com.reecedunn.espeak'
    ;;
  'dumpsys package com.android.talkback')
    echo 'Service: com.google.android.marvin.talkback.TalkBackService'
    ;;
  'dumpsys accessibility')
    echo 'User state['
    if [[ "${MOCK_CASE:-pass}" == 'unbound' ]]; then
      echo ' Bound services:{}'
    else
      echo " Bound services:{$talkback_service}"
    fi
    echo " Enabled services:{$talkback_service}"
    echo ' Binding services:{}'
    echo ' Crashed services:{}'
    echo ' Client list info:{}'
    echo ']'
    ;;
  'dumpsys audio')
    [[ "${MOCK_CASE:-pass}" == 'no-audio' ]] || echo 'AudioService state'
    ;;
  'dumpsys media.audio_flinger')
    [[ "${MOCK_CASE:-pass}" == 'no-audio-flinger' ]] || echo 'AudioFlinger state'
    ;;
  'dumpsys media.audio_policy')
    [[ "${MOCK_CASE:-pass}" == 'no-audio-policy' ]] || echo 'AudioPolicy state'
    ;;
  'dumpsys input')
    [[ "${MOCK_CASE:-pass}" == 'no-input' ]] || echo 'Input Manager State'
    ;;
  'dumpsys SurfaceFlinger')
    [[ "${MOCK_CASE:-pass}" == 'no-surfaceflinger' ]] || echo 'SurfaceFlinger state'
    ;;
  'dumpsys display')
    [[ "${MOCK_CASE:-pass}" == 'no-display' ]] || echo 'Display Manager State'
    ;;
  'logcat -c')
    exit 0
    ;;
  'am broadcast -a org.accessibledroid.bootstrap.SPEECH_SMOKE -n org.accessibledroid.bootstrap/.SpeechSmokeReceiver')
    echo 'Broadcast completed: result=0'
    ;;
  'logcat -d -s AccessibleTtsSmoke:V')
    if [[ "${MOCK_CASE:-pass}" == 'tts-fail' ]]; then
      echo 'E AccessibleTtsSmoke: ACCESSIBLE_TTS_SMOKE=FAIL stage=TTS_SYNTHESIS errorCode=-1'
    elif [[ "${MOCK_CASE:-pass}" == 'tts-no-french' ]]; then
      echo 'I AccessibleTtsSmoke: TTS_SMOKE_EN_US=PASS'
      echo 'I AccessibleTtsSmoke: ACCESSIBLE_TTS_SMOKE=PASS'
    else
      echo 'I AccessibleTtsSmoke: TTS_SMOKE_EN_US=PASS'
      echo 'I AccessibleTtsSmoke: TTS_SMOKE_FR_FR=PASS'
      echo 'I AccessibleTtsSmoke: ACCESSIBLE_TTS_SMOKE=PASS'
    fi
    ;;
  *)
    echo "unexpected adb shell command: $cmd" >&2
    exit 91
    ;;
esac
MOCK
chmod +x "$MOCK_ADB"

run_case() {
  local case_name="$1"
  local expected="$2"
  local output status

  set +e
  output="$(
    MOCK_CASE="$case_name" \
      ADB="$MOCK_ADB" \
      BOOT_TIMEOUT_SECONDS=0 \
      ACCESSIBILITY_BIND_TIMEOUT_SECONDS=0 \
      TTS_SMOKE_TIMEOUT_SECONDS=0 \
      bash "$VALIDATOR" 2>&1
  )"
  status=$?
  set -e

  if [[ "$expected" == 'pass' ]]; then
    if (( status != 0 )); then
      echo "ERROR: case $case_name unexpectedly failed" >&2
      echo "$output" >&2
      return 1
    fi
    for marker in \
      'TALKBACK_BOUND = PASS' \
      'AUDIO_POLICY = PASS' \
      'INPUT_MANAGER = PASS' \
      'SURFACE_FLINGER = PASS' \
      'DISPLAY_MANAGER = PASS' \
      'TTS_SYNTHESIS_EN_US = PASS' \
      'TTS_SYNTHESIS_FR_FR = PASS' \
      'ACCESSIBILITY_RUNTIME = PASS'; do
      grep -Fq "$marker" <<<"$output"
    done
  else
    if (( status == 0 )); then
      echo "ERROR: case $case_name unexpectedly passed" >&2
      echo "$output" >&2
      return 1
    fi
  fi

  echo "ACCESSIBILITY_VALIDATOR_CASE[$case_name] = PASS"
}

run_case pass pass
run_case disabled fail
run_case unbound fail
run_case no-audio fail
run_case no-audio-flinger fail
run_case no-audio-policy fail
run_case no-input fail
run_case no-surfaceflinger fail
run_case no-display fail
run_case tts-fail fail
run_case tts-no-french fail

echo 'ACCESSIBILITY_RUNTIME_VALIDATOR_TESTS = PASS'
