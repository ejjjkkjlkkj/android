#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

AOSP_DIR="${AOSP_DIR:-$HOME/aosp-accessible-android}"
SRC_ROOT="${ACCESSIBILITY_SRC_DIR:-$HOME/accessibledroid-accessibility-src}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
DEST_DIR="$AOSP_DIR/vendor/accessibledroid/generated-apps"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

[[ -d "$AOSP_DIR/.repo" ]] || fail "AOSP checkout not found at $AOSP_DIR"
[[ -d "$SRC_ROOT/talkback/.git" ]] || fail "TalkBack source missing; run scripts/sync-accessibility-upstreams.sh"
[[ -d "$SRC_ROOT/espeak-ng/.git" ]] || fail "eSpeak NG source missing; run scripts/sync-accessibility-upstreams.sh"
[[ -n "$SDK_ROOT" && -d "$SDK_ROOT" ]] || fail "ANDROID_SDK_ROOT or ANDROID_HOME must point to an Android SDK"

[[ "$(git -C "$SRC_ROOT/talkback" rev-parse HEAD)" == "$TALKBACK_REV" ]] || fail "TalkBack source revision drift"
[[ "$(git -C "$SRC_ROOT/espeak-ng" rev-parse HEAD)" == "$ESPEAK_NG_REV" ]] || fail "eSpeak NG source revision drift"

mkdir -p "$DEST_DIR"
rm -f "$DEST_DIR/talkback.apk" "$DEST_DIR/espeak-ng.apk"

build_talkback() {
  echo "==> Build TalkBack from pinned source"
  cd "$SRC_ROOT/talkback"
  ANDROID_SDK="$SDK_ROOT" GRADLE_DEBUG='' GRADLE_STACKTRACE='' bash ./build.sh

  local apk
  apk="$(find . -type f -path '*/build/outputs/apk/*' -name '*.apk' ! -name '*test*' | sort | head -n 1)"
  [[ -n "$apk" ]] || fail "TalkBack build produced no APK"
  cp -f "$apk" "$DEST_DIR/talkback.apk"
}

build_espeak() {
  echo "==> Build eSpeak NG Android TTS from pinned source"
  cd "$SRC_ROOT/espeak-ng/android"
  chmod +x ./gradlew
  ANDROID_HOME="$SDK_ROOT" ANDROID_SDK_ROOT="$SDK_ROOT" ./gradlew --no-daemon assembleDebug

  local apk
  apk="$(find build -type f -path '*/outputs/apk/*' -name '*.apk' ! -name '*test*' | sort | head -n 1)"
  [[ -n "$apk" ]] || fail "eSpeak NG build produced no APK"
  cp -f "$apk" "$DEST_DIR/espeak-ng.apk"
}

build_talkback
build_espeak

[[ -s "$DEST_DIR/talkback.apk" ]] || fail "TalkBack staged APK is empty"
[[ -s "$DEST_DIR/espeak-ng.apk" ]] || fail "eSpeak staged APK is empty"

sha256sum "$DEST_DIR/talkback.apk" "$DEST_DIR/espeak-ng.apk" > "$DEST_DIR/SHA256SUMS.generated"

cat > "$DEST_DIR/SOURCE-PROVENANCE.generated" <<EOF
TalkBack URL: $TALKBACK_URL
TalkBack revision: $TALKBACK_REV
TalkBack package: $TALKBACK_PACKAGE
TalkBack service: $TALKBACK_SERVICE
eSpeak NG URL: $ESPEAK_NG_URL
eSpeak NG revision: $ESPEAK_NG_REV
eSpeak package: $ESPEAK_PACKAGE
EOF

echo "ACCESSIBILITY_APPS = BUILT"
echo "OUTPUT = $DEST_DIR"
cat "$DEST_DIR/SHA256SUMS.generated"
