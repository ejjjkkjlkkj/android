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
talkback_service='com.google.android.accessibility.talkback/com.google.android.marvin.talkback.TalkBackService'

case "$cmd" in
  'getprop sys.boot_completed')
    echo 1
    ;;
  'pm path com.google.android.accessibility.talkback')
    echo 'package:/system/priv-app/AccessibleTalkBack/AccessibleTalkBack.apk'
    ;;
  'pm path com.reecedunn.espeak')
    echo 'package:/system/priv-app/AccessibleEspeakTts/AccessibleEspeakTts.apk'
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
  'dumpsys package com.google.android.accessibility.talkback')
    echo 'Service: com.google.android.marvin.talkback.TalkBackService'
    ;;
  'dumpsys accessibility')
    echo 'ACCESSIBILITY MANAGER (dumpsys accessibility)'
    echo 'User state['
    echo " Enabled services:{$talkback_service}"
    if [[ "${MOCK_CASE:-pass}" == 'binding' ]]; then
      echo " Binding services:{$talkback_service}"
    else
      echo ' Binding services:{}'
    fi
    if [[ "${MOCK_CASE:-pass}" == 'crashed' ]]; then
      echo " Crashed services:{$talkback_service}"
    else
      echo ' Crashed services:{}'
    fi
    echo ']'
    ;;
  'dumpsys activity services com.google.android.accessibility.talkback')
    if [[ "${MOCK_CASE:-pass}" == 'not-connected' ]]; then
      echo 'No services match: com.google.android.accessibility.talkback'
    else
      echo 'ServiceRecord{42 com.google.android.accessibility.talkback/com.google.android.marvin.talkback.TalkBackService}'
    fi
    ;;
  'dumpsys audio')
    echo 'AudioService state'
    ;;
  'dumpsys media.audio_flinger')
    if [[ "${MOCK_CASE:-pass}" != 'no-audio-flinger' ]]; then
      echo 'AudioFlinger state'
    fi
    ;;
  'dumpsys media.audio_policy')
    if [[ "${MOCK_CASE:-pass}" != 'no-audio-policy' ]]; then
      echo 'AudioPolicy state'
    fi
    ;;
  'dumpsys input')
    echo 'Input Manager State'
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
      BOOT_TIMEOUT_SECONDS=1 \
      ACCESSIBILITY_CONNECT_TIMEOUT_SECONDS=0 \
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
    grep -Fq 'TALKBACK_CONNECTED = PASS' <<<"$output"
    grep -Fq 'AUDIO_FLINGER = PASS' <<<"$output"
    grep -Fq 'AUDIO_POLICY = PASS' <<<"$output"
    grep -Fq 'INPUT_MANAGER = PASS' <<<"$output"
    grep -Fq 'ACCESSIBILITY_RUNTIME = PASS' <<<"$output"
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
run_case not-connected fail
run_case binding fail
run_case crashed fail
run_case no-audio-flinger fail
run_case no-audio-policy fail

echo 'ACCESSIBILITY_RUNTIME_VALIDATOR_TESTS = PASS'
