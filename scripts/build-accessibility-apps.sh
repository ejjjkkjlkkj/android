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
REUSE_ACCESSIBILITY_APPS="${REUSE_ACCESSIBILITY_APPS:-0}"
CACHE_MARKER="$DEST_DIR/BUILD-CACHE.generated"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

[[ -d "$AOSP_DIR/.repo" ]] || fail "AOSP checkout not found at $AOSP_DIR"
[[ -d "$SRC_ROOT/talkback/.git" ]] || fail "TalkBack source missing; run scripts/sync-accessibility-upstreams.sh"
[[ -d "$SRC_ROOT/espeak-ng/.git" ]] || fail "eSpeak NG source missing; run scripts/sync-accessibility-upstreams.sh"
[[ -d "$SDK_ROOT" ]] || fail "Android SDK not found at $SDK_ROOT; run scripts/bootstrap-android-sdk.sh"
[[ -x "$GRADLE_ROOT/bin/gradle" ]] || fail "Gradle $TALKBACK_GRADLE_VERSION not found; run scripts/bootstrap-android-sdk.sh"

TALKBACK_HEAD="$(git -C "$SRC_ROOT/talkback" rev-parse HEAD)"
ESPEAK_HEAD="$(git -C "$SRC_ROOT/espeak-ng" rev-parse HEAD)"
[[ "$TALKBACK_HEAD" == "$TALKBACK_REV" ]] || fail "TalkBack source revision drift"
[[ "$ESPEAK_HEAD" == "$ESPEAK_NG_REV" ]] || fail "eSpeak NG source revision drift"

AAPT2="$(find "$SDK_ROOT/build-tools" -type f -name aapt2 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "$AAPT2" && -x "$AAPT2" ]] || fail "aapt2 not found in Android SDK build-tools"

export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export PATH="$GRADLE_ROOT/bin:$SDK_ROOT/platform-tools:$SDK_ROOT/cmdline-tools/latest/bin:$PATH"

mkdir -p "$DEST_DIR"

apk_package() {
  "$AAPT2" dump packagename "$1" | sed -n '1p' | tr -d '\r'
}

apk_manifest_tree() {
  "$AAPT2" dump xmltree "$1" --file AndroidManifest.xml
}

apk_has_native_lib() {
  local apk_path="$1"
  local abi="$2"
  local library_name="$3"
  python3 - "$apk_path" "$abi" "$library_name" <<'PY'
import sys
import zipfile

apk_path, abi, library_name = sys.argv[1:]
entry = f"lib/{abi}/{library_name}"
with zipfile.ZipFile(apk_path) as archive:
    raise SystemExit(0 if entry in archive.namelist() else 1)
PY
}

accessibility_build_fingerprint() {
  {
    sha256sum "$ROOT_DIR/config/accessibility-upstreams.env"
    sha256sum "$ROOT_DIR/config/toolchain.env"
    sha256sum "$ROOT_DIR/scripts/build-accessibility-apps.sh"
    printf 'talkback_head=%s\n' "$TALKBACK_HEAD"
    printf 'espeak_head=%s\n' "$ESPEAK_HEAD"
    printf 'talkback_package=%s\n' "$TALKBACK_PACKAGE"
    printf 'talkback_service=%s\n' "$TALKBACK_SERVICE"
    printf 'espeak_package=%s\n' "$ESPEAK_PACKAGE"
    printf 'gradle=%s\n' "$TALKBACK_GRADLE_VERSION"
    printf 'guest_abi=x86_64\n'
  } | sha256sum | awk '{print $1}'
}

verify_accessibility_apks() {
  [[ -s "$DEST_DIR/talkback.apk" ]] || return 1
  [[ -s "$DEST_DIR/espeak-ng.apk" ]] || return 1
  [[ -s "$DEST_DIR/SHA256SUMS.generated" ]] || return 1

  (cd "$DEST_DIR" && sha256sum -c SHA256SUMS.generated >/dev/null 2>&1) || return 1

  TALKBACK_BUILT_PACKAGE="$(apk_package "$DEST_DIR/talkback.apk")"
  ESPEAK_BUILT_PACKAGE="$(apk_package "$DEST_DIR/espeak-ng.apk")"
  [[ "$TALKBACK_BUILT_PACKAGE" == "$TALKBACK_PACKAGE" ]] || return 1
  [[ "$ESPEAK_BUILT_PACKAGE" == "$ESPEAK_PACKAGE" ]] || return 1

  local talkback_service_class
  local talkback_manifest_tree
  local espeak_manifest_tree
  talkback_service_class="${TALKBACK_SERVICE#*/}"
  talkback_manifest_tree="$(apk_manifest_tree "$DEST_DIR/talkback.apk")"
  espeak_manifest_tree="$(apk_manifest_tree "$DEST_DIR/espeak-ng.apk")"
  grep -Fq "$talkback_service_class" <<<"$talkback_manifest_tree" || return 1
  grep -Fq 'android.intent.action.TTS_SERVICE' <<<"$espeak_manifest_tree" || return 1

  # AccessibleAndroid is x86_64. TalkBack eagerly constructs its braille stack,
  # which loads brlttywrap at service startup, so an ARM-only APK is unusable
  # even when the Java package and accessibility-service manifest are valid.
  apk_has_native_lib "$DEST_DIR/talkback.apk" x86_64 libbrlttywrap.so || return 1
  apk_has_native_lib "$DEST_DIR/talkback.apk" x86_64 liblouiswrap.so || return 1
  apk_has_native_lib "$DEST_DIR/espeak-ng.apk" x86_64 libttsespeak.so || return 1
  return 0
}

BUILD_FINGERPRINT="$(accessibility_build_fingerprint)"

if [[ "$REUSE_ACCESSIBILITY_APPS" == "1" && -s "$CACHE_MARKER" ]]; then
  cached_fingerprint="$(tr -d '[:space:]' < "$CACHE_MARKER")"
  if [[ "$cached_fingerprint" == "$BUILD_FINGERPRINT" ]] && verify_accessibility_apks; then
    echo "ACCESSIBILITY_APPS_CACHE = HIT"
    echo "ACCESSIBILITY_APPS_FINGERPRINT = $BUILD_FINGERPRINT"
    echo "ACCESSIBILITY_APPS = BUILT"
    echo "TALKBACK_APK_PACKAGE = $TALKBACK_BUILT_PACKAGE"
    echo "TALKBACK_SERVICE = VERIFIED"
    echo "TALKBACK_X86_64_NATIVE = VERIFIED"
    echo "ESPEAK_APK_PACKAGE = $ESPEAK_BUILT_PACKAGE"
    echo "ESPEAK_TTS_SERVICE = VERIFIED"
    echo "ESPEAK_X86_64_NATIVE = VERIFIED"
    echo "OUTPUT = $DEST_DIR"
    cat "$DEST_DIR/SHA256SUMS.generated"
    exit 0
  fi
  echo "ACCESSIBILITY_APPS_CACHE = STALE"
fi

echo "ACCESSIBILITY_APPS_CACHE = MISS"
rm -f \
  "$DEST_DIR/talkback.apk" \
  "$DEST_DIR/espeak-ng.apk" \
  "$DEST_DIR/SHA256SUMS.generated" \
  "$DEST_DIR/SOURCE-PROVENANCE.generated" \
  "$CACHE_MARKER"

build_talkback() {
  echo "==> Build TalkBack from pinned source"
  cd "$SRC_ROOT/talkback"

  # Restore pinned upstream source before applying reproducible build-only
  # patches. Upstream currently restricts native TalkBack/Braille libraries to
  # ARM, while AccessibleAndroid runs x86_64.
  git reset --hard "$TALKBACK_REV" >/dev/null

  python3 - <<'PY'
from pathlib import Path

path = Path("shared.gradle")
text = path.read_text(encoding="utf-8")
old = 'abiFilters "armeabi-v7a", "arm64-v8a"'
new = 'abiFilters "armeabi-v7a", "arm64-v8a", "x86_64"'
if old not in text:
    raise SystemExit("ERROR: pinned TalkBack abiFilters contract changed")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
  grep -Fq 'abiFilters "armeabi-v7a", "arm64-v8a", "x86_64"' shared.gradle \
    || fail "TalkBack x86_64 ABI patch was not applied"

  # ACCESSIBLEANDROID_TALKBACK_JVM17_ROOT_PATCH
  if ! grep -Fq 'ACCESSIBLEANDROID_KOTLIN_JVM17_SUBPROJECTS' build.gradle; then
    cat >> build.gradle <<'GRADLEPATCH'

// ACCESSIBLEANDROID_KOTLIN_JVM17_SUBPROJECTS
// Java already targets 17 in shared.gradle. Keep Kotlin aligned on JDK 21 hosts.
subprojects {
    pluginManager.withPlugin("org.jetbrains.kotlin.android") {
        tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile).configureEach {
            kotlinOptions {
                jvmTarget = "17"
            }
        }
    }
}
GRADLEPATCH
  fi

  echo "TALKBACK_KOTLIN_JVM_TARGET = 17"
  echo "TALKBACK_NATIVE_ABIS = armeabi-v7a,arm64-v8a,x86_64"
  ANDROID_SDK="$SDK_ROOT" GRADLE_DEBUG='' GRADLE_STACKTRACE='' bash ./build.sh

  local apk
  apk="$(find . -type f -path '*/build/outputs/apk/*' -name '*.apk' ! -name '*test*' | sort | sed -n '1p')"
  [[ -n "$apk" ]] || fail "TalkBack build produced no APK"
  cp -f "$apk" "$DEST_DIR/talkback.apk"
}

build_espeak() {
  echo "==> Build eSpeak NG Android TTS from pinned source"
  cd "$SRC_ROOT/espeak-ng/android"
  chmod +x ./gradlew
  ANDROID_HOME="$SDK_ROOT" ANDROID_SDK_ROOT="$SDK_ROOT" ./gradlew --no-daemon assembleDebug

  local apk
  apk="$(find build -type f -path '*/outputs/apk/*' -name '*.apk' ! -name '*test*' | sort | sed -n '1p')"
  [[ -n "$apk" ]] || fail "eSpeak NG build produced no APK"
  cp -f "$apk" "$DEST_DIR/espeak-ng.apk"
}

build_talkback
build_espeak

[[ -s "$DEST_DIR/talkback.apk" ]] || fail "TalkBack staged APK is empty"
[[ -s "$DEST_DIR/espeak-ng.apk" ]] || fail "eSpeak staged APK is empty"
(
  cd "$DEST_DIR"
  sha256sum talkback.apk espeak-ng.apk > SHA256SUMS.generated
)

verify_accessibility_apks || fail "built accessibility APK verification failed"

cat > "$DEST_DIR/SOURCE-PROVENANCE.generated" <<EOF
TalkBack URL: $TALKBACK_URL
TalkBack revision: $TALKBACK_REV
TalkBack configured package: $TALKBACK_PACKAGE
TalkBack built APK package: $TALKBACK_BUILT_PACKAGE
TalkBack service: $TALKBACK_SERVICE
TalkBack required guest ABI: x86_64
TalkBack x86_64 brlttywrap: verified
TalkBack x86_64 louiswrap: verified
eSpeak NG URL: $ESPEAK_NG_URL
eSpeak NG revision: $ESPEAK_NG_REV
eSpeak configured package: $ESPEAK_PACKAGE
eSpeak required guest ABI: x86_64
eSpeak x86_64 ttsespeak: verified
EOF

printf '%s\n' "$BUILD_FINGERPRINT" > "$CACHE_MARKER"

echo "ACCESSIBILITY_APPS_FINGERPRINT = $BUILD_FINGERPRINT"
echo "ACCESSIBILITY_APPS = BUILT"
echo "TALKBACK_APK_PACKAGE = $TALKBACK_BUILT_PACKAGE"
echo "TALKBACK_SERVICE = VERIFIED"
echo "TALKBACK_X86_64_NATIVE = VERIFIED"
echo "ESPEAK_APK_PACKAGE = $ESPEAK_BUILT_PACKAGE"
echo "ESPEAK_TTS_SERVICE = VERIFIED"
echo "ESPEAK_X86_64_NATIVE = VERIFIED"
echo "OUTPUT = $DEST_DIR"
cat "$DEST_DIR/SHA256SUMS.generated"
