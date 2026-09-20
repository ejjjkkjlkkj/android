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
talkback_package='com.android.talkback'
talkback_service='com.android.talkback/com.google.android.marvin.talkback.TalkBackService'
espeak_package='com.reecedunn.espeak'
bootstrap_package='org.accessibledroid.bootstrap'

case "$cmd" in
  'getprop sys.boot_completed')
    echo 1
    ;;
  "pm path $talkback_package")
    if [[ "${MOCK_CASE:-pass}" != 'missing-talkback' ]]; then
      echo 'package:/system/priv-app/AccessibleTalkBack/AccessibleTalkBack.apk'
    fi
    ;;
  "pm path $espeak_package")
    echo 'package:/system/priv-app/AccessibleEspeakTts/AccessibleEspeakTts.apk'
    ;;
  "pm path $bootstrap_package")
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
    if [[ "${MOCK_CASE:-pass}" == 'wrong-default-tts' ]]; then
      echo 'com.example.other'
    else
      echo "$espeak_package"
    fi
    ;;
  "dumpsys package $talkback_package")
    echo 'Service: com.google.android.marvin.talkback.TalkBackService'
    ;;
  'dumpsys accessibility')
    echo 'ACCESSIBILITY MANAGER (dumpsys accessibility)'
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
    echo 'AudioService state'
    ;;
  'dumpsys media.audio_flinger')
    if [[ "${MOCK_CASE:-pass}" != 'no-audio-flinger' ]]; then
      echo 'AudioFlinger state'
    fi
    ;;
  'logcat -c')
    ;;
  "am broadcast -a org.accessibledroid.bootstrap.SPEECH_SMOKE -n org.accessibledroid.bootstrap/.SpeechSmokeReceiver")
    if [[ "${MOCK_CASE:-pass}" == 'broadcast-fail' ]]; then
      echo 'Broadcast failed'
    else
      echo 'Broadcast completed: result=0'
    fi
    ;;
  'logcat -d -s AccessibleTtsSmoke:V')
    case "${MOCK_CASE:-pass}" in
      tts-fail)
        echo 'E/AccessibleTtsSmoke: ACCESSIBLE_TTS_SMOKE=FAIL stage=TTS_SYNTHESIS'
        ;;
      missing-en-marker)
        echo 'I/AccessibleTtsSmoke: TTS_SMOKE_FR_FR=PASS'
        echo 'I/AccessibleTtsSmoke: ACCESSIBLE_TTS_SMOKE=PASS'
        ;;
      missing-fr-marker)
        echo 'I/AccessibleTtsSmoke: TTS_SMOKE_EN_US=PASS'
        echo 'I/AccessibleTtsSmoke: ACCESSIBLE_TTS_SMOKE=PASS'
        ;;
      *)
        echo 'I/AccessibleTtsSmoke: TTS_SMOKE_EN_US=PASS'
        echo 'I/AccessibleTtsSmoke: TTS_SMOKE_FR_FR=PASS'
        echo 'I/AccessibleTtsSmoke: ACCESSIBLE_TTS_SMOKE=PASS'
        ;;
    esac
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
    grep -Fq 'TALKBACK_BOUND = PASS' <<<"$output"
    grep -Fq 'AUDIO_FLINGER = PASS' <<<"$output"
    grep -Fq 'TTS_SYNTHESIS_EN_US = PASS' <<<"$output"
    grep -Fq 'TTS_SYNTHESIS_FR_FR = PASS' <<<"$output"
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
run_case missing-talkback fail
run_case disabled fail
run_case wrong-default-tts fail
run_case unbound fail
run_case no-audio-flinger fail
run_case broadcast-fail fail
run_case tts-fail fail
run_case missing-en-marker fail
run_case missing-fr-marker fail

echo 'ACCESSIBILITY_RUNTIME_VALIDATOR_TESTS = PASS'
