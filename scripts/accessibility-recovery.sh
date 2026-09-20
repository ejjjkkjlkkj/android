#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

ADB="${ADB:-adb}"
ADB_SERIAL="${ADB_SERIAL:-}"

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

run_adb start-server >/dev/null
run_adb wait-for-device

talkback_path="$(run_shell pm path "$TALKBACK_PACKAGE" 2>/dev/null | clean_cr || true)"
[[ "$talkback_path" == package:* ]] || fail "TalkBack package is not installed: $TALKBACK_PACKAGE"

espeak_path="$(run_shell pm path "$ESPEAK_PACKAGE" 2>/dev/null | clean_cr || true)"
[[ "$espeak_path" == package:* ]] || fail "eSpeak TTS package is not installed: $ESPEAK_PACKAGE"

current="$(run_shell settings get secure enabled_accessibility_services | clean_cr)"
if [[ "$current" == "null" ]]; then
  current=""
fi

case ":${current}:" in
  *":${TALKBACK_SERVICE}:"*)
    updated="$current"
    ;;
  *)
    if [[ -n "$current" ]]; then
      updated="$current:$TALKBACK_SERVICE"
    else
      updated="$TALKBACK_SERVICE"
    fi
    ;;
esac

run_shell settings put secure enabled_accessibility_services "$updated"
run_shell settings put secure accessibility_enabled 1
run_shell settings put secure tts_default_synth "$ESPEAK_PACKAGE"

# Give AccessibilityManager a moment to observe the secure-setting changes.
sleep 2

ADB="$ADB" ADB_SERIAL="$ADB_SERIAL"   bash "$ROOT_DIR/scripts/verify-accessibility-runtime-adb.sh"

echo "ACCESSIBILITY_RECOVERY = PASS"
