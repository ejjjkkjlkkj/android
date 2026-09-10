#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/toolchain.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

SRC_ROOT="$ACCESSIBILITY_SRC_DIR"
SDK_ROOT="$ANDROID_SDK_ROOT"
GRADLE_ROOT="$ROOT_DIR/.work/tools/gradle-$TALKBACK_GRADLE_VERSION"
DEST_DIR="$AOSP_DIR/vendor/accessibledroid/generated-apps"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

[[ -d "$AOSP_DIR/.repo" ]] || fail "AOSP checkout not found at $AOSP_DIR"
[[ -d "$SRC_ROOT/talkback/.git" ]] || fail "TalkBack source missing; run scripts/sync-accessibility-upstreams.sh"
[[ -d "$SRC_ROOT/espeak-ng/.git" ]] || fail "eSpeak NG source missing; run scripts/sync-accessibility-upstreams.sh"
[[ -d "$SDK_ROOT" ]] || fail "Android SDK not found at $SDK_ROOT; run scripts/bootstrap-android-sdk.sh"
[[ -x "$GRADLE_ROOT/bin/gradle" ]] || fail "Gradle $TALKBACK_GRADLE_VERSION not found; run scripts/bootstrap-android-sdk.sh"

[[ "$(git -C "$SRC_ROOT/talkback" rev-parse HEAD)" == "$TALKBACK_REV" ]] || fail "TalkBack source revision drift"
[[ "$(git -C "$SRC_ROOT/espeak-ng" rev-parse HEAD)" == "$ESPEAK_NG_REV" ]] || fail "eSpeak NG source revision drift"

AAPT2="$(find "$SDK_ROOT/build-tools" -type f -name aapt2 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "$AAPT2" && -x "$AAPT2" ]] || fail "aapt2 not found in Android SDK build-tools"

export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export PATH="$GRADLE_ROOT/bin:$SDK_ROOT/platform-tools:$SDK_ROOT/cmdline-tools/latest/bin:$PATH"

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

apk_package() {
  "$AAPT2" dump badging "$1" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1
}

build_talkback
build_espeak

[[ -s "$DEST_DIR/talkback.apk" ]] || fail "TalkBack staged APK is empty"
[[ -s "$DEST_DIR/espeak-ng.apk" ]] || fail "eSpeak staged APK is empty"

TALKBACK_BUILT_PACKAGE="$(apk_package "$DEST_DIR/talkback.apk")"
ESPEAK_BUILT_PACKAGE="$(apk_package "$DEST_DIR/espeak-ng.apk")"
[[ -n "$TALKBACK_BUILT_PACKAGE" ]] || fail "unable to determine TalkBack APK package"
[[ -n "$ESPEAK_BUILT_PACKAGE" ]] || fail "unable to determine eSpeak APK package"

sha256sum "$DEST_DIR/talkback.apk" "$DEST_DIR/espeak-ng.apk" > "$DEST_DIR/SHA256SUMS.generated"

cat > "$DEST_DIR/SOURCE-PROVENANCE.generated" <<EOF
TalkBack URL: $TALKBACK_URL
TalkBack revision: $TALKBACK_REV
TalkBack configured package: $TALKBACK_PACKAGE
TalkBack built APK package: $TALKBACK_BUILT_PACKAGE
TalkBack service: $TALKBACK_SERVICE
eSpeak NG URL: $ESPEAK_NG_URL
eSpeak NG revision: $ESPEAK_NG_REV
eSpeak configured package: $ESPEAK_PACKAGE
eSpeak built APK package: $ESPEAK_BUILT_PACKAGE
EOF

echo "ACCESSIBILITY_APPS = BUILT"
echo "TALKBACK_APK_PACKAGE = $TALKBACK_BUILT_PACKAGE"
echo "ESPEAK_APK_PACKAGE = $ESPEAK_BUILT_PACKAGE"
echo "OUTPUT = $DEST_DIR"
cat "$DEST_DIR/SHA256SUMS.generated"
