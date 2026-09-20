#!/system/bin/sh
set -eu

TALKBACK_SERVICE='com.android.talkback/com.google.android.marvin.talkback.TalkBackService'
ESPEAK_PACKAGE='com.reecedunn.espeak'
TTS_ACTION='org.accessibledroid.bootstrap.SPEECH_SMOKE'
TTS_COMPONENT='org.accessibledroid.bootstrap/.SpeechSmokeReceiver'

say() {
  echo "$*"
}

fail() {
  say "ACCESSIBILITY_SELFTEST = FAIL: $*"
  exit 2
}

wait_for_bound_talkback() {
  attempt=0
  while [ "$attempt" -lt 60 ]; do
    dump="$(dumpsys accessibility 2>/dev/null || true)"
    bound="$(printf '%s\n' "$dump" | sed -n '/Bound services:{/,/Enabled services:{/p')"
    if printf '%s\n' "$bound" | grep -Fq "$TALKBACK_SERVICE"; then
      say 'TALKBACK_BOUND = PASS'
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

focused_node() {
  file="$1"
  grep -o '<node[^>]*focused="true"[^>]*>' "$file" 2>/dev/null | head -n 1 || true
}

capture_ui() {
  file="$1"
  rm -f "$file"
  uiautomator dump "$file" >/dev/null 2>&1 || return 1
  [ -s "$file" ]
}

say 'ACCESSIBILITY_SELFTEST = START'

[ "$(settings get secure accessibility_enabled 2>/dev/null)" = "1" ] ||   fail 'accessibility_enabled is not 1'

enabled_services="$(settings get secure enabled_accessibility_services 2>/dev/null || true)"
case ":$enabled_services:" in
  *":$TALKBACK_SERVICE:"*) say 'TALKBACK_ENABLED = PASS' ;;
  *) fail "TalkBack service is not enabled: $enabled_services" ;;
esac

wait_for_bound_talkback || fail 'TalkBack never became bound to AccessibilityManagerService'

[ "$(settings get secure tts_default_synth 2>/dev/null)" = "$ESPEAK_PACKAGE" ] ||   fail 'offline eSpeak is not the default TTS engine'
say 'OFFLINE_TTS_DEFAULT = PASS'

audio_dump="$(dumpsys audio 2>/dev/null || true)"
[ -n "$audio_dump" ] || fail 'AudioService dump is empty'
flinger_dump="$(dumpsys media.audio_flinger 2>/dev/null || true)"
[ -n "$flinger_dump" ] || fail 'AudioFlinger dump is empty'
say 'AUDIO_SERVICE = PASS'
say 'AUDIO_FLINGER = PASS'

input keyevent KEYCODE_HOME >/dev/null 2>&1 || fail 'KEYCODE_HOME injection failed'
sleep 1
before_file=/data/local/tmp/accessible-selftest-before.xml
capture_ui "$before_file" || fail 'initial UIAutomator hierarchy dump failed'
before_focus="$(focused_node "$before_file")"
keyboard_pass=0
attempt=1
while [ "$attempt" -le 4 ]; do
  input keyevent KEYCODE_TAB >/dev/null 2>&1 || fail 'KEYCODE_TAB injection failed'
  sleep 1
  after_file="/data/local/tmp/accessible-selftest-after-$attempt.xml"
  capture_ui "$after_file" || fail 'UIAutomator hierarchy dump failed after Tab'
  after_focus="$(focused_node "$after_file")"
  if [ -n "$after_focus" ] && [ "$after_focus" != "$before_focus" ]; then
    keyboard_pass=1
    break
  fi
  attempt=$((attempt + 1))
done
[ "$keyboard_pass" = "1" ] || fail 'Tab did not change the focused accessibility node'
say 'KEYBOARD_FOCUS_NAVIGATION = PASS'

logcat -c >/dev/null 2>&1 || true
broadcast="$(am broadcast -a "$TTS_ACTION" -n "$TTS_COMPONENT" 2>&1 || true)"
printf '%s\n' "$broadcast" | grep -Fq 'Broadcast completed' ||   fail 'TTS smoke broadcast did not complete'

attempt=0
while [ "$attempt" -lt 60 ]; do
  tts_log="$(logcat -d -s AccessibleTtsSmoke:V 2>/dev/null || true)"
  if printf '%s\n' "$tts_log" | grep -Fq 'ACCESSIBLE_TTS_SMOKE=FAIL'; then
    fail 'offline TTS smoke receiver reported failure'
  fi
  if printf '%s\n' "$tts_log" | grep -Fq 'ACCESSIBLE_TTS_SMOKE=PASS'; then
    printf '%s\n' "$tts_log" | grep -Fq 'TTS_SMOKE_EN_US=PASS' ||       fail 'English offline TTS synthesis did not complete'
    printf '%s\n' "$tts_log" | grep -Fq 'TTS_SMOKE_FR_FR=PASS' ||       fail 'French offline TTS synthesis did not complete'
    say 'TTS_SYNTHESIS_EN_US = PASS'
    say 'TTS_SYNTHESIS_FR_FR = PASS'
    say 'ACCESSIBILITY_RUNTIME = PASS'
    say 'ACCESSIBILITY_SELFTEST = PASS'
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 1
done

fail 'offline TTS smoke test timed out'
