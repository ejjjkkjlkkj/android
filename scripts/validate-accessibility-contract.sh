#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

fail() {
  echo "ERROR: $*" >&2
  exit 2
}

BOOT_RECEIVER="$ROOT_DIR/vendor/accessibledroid/bootstrap/src/org/accessibledroid/bootstrap/BootReceiver.java"
SMOKE_RECEIVER="$ROOT_DIR/vendor/accessibledroid/bootstrap/src/org/accessibledroid/bootstrap/SpeechSmokeReceiver.java"
MANIFEST="$ROOT_DIR/vendor/accessibledroid/bootstrap/AndroidManifest.xml"
PRODUCT_MK="$ROOT_DIR/vendor/accessibledroid/product/accessibility.mk"
RUNTIME_VALIDATOR="$ROOT_DIR/scripts/verify-accessibility-runtime-adb.sh"
BUILD_APPS="$ROOT_DIR/scripts/build-accessibility-apps.sh"

for file in "$BOOT_RECEIVER" "$SMOKE_RECEIVER" "$MANIFEST" "$PRODUCT_MK" "$RUNTIME_VALIDATOR" "$BUILD_APPS"; do
  [[ -s "$file" ]] || fail "required accessibility contract file is missing: $file"
done

service_package="${TALKBACK_SERVICE%%/*}"
[[ "$service_package" == "$TALKBACK_PACKAGE" ]] || \
  fail "TalkBack service package does not match TALKBACK_PACKAGE"

grep -Fq "private static final String TALKBACK_PACKAGE = \"$TALKBACK_PACKAGE\";" "$BOOT_RECEIVER" || \
  fail "BootReceiver TalkBack package drift"
grep -Fq "private static final String TALKBACK_CLASS = \"${TALKBACK_SERVICE#*/}\";" "$BOOT_RECEIVER" || \
  fail "BootReceiver TalkBack service class drift"
grep -Fq "private static final String ESPEAK_PACKAGE = \"$ESPEAK_PACKAGE\";" "$BOOT_RECEIVER" || \
  fail "BootReceiver eSpeak package drift"

grep -Fq "<package android:name=\"$TALKBACK_PACKAGE\" />" "$MANIFEST" || \
  fail "bootstrap manifest cannot query TalkBack package"
grep -Fq "<package android:name=\"$ESPEAK_PACKAGE\" />" "$MANIFEST" || \
  fail "bootstrap manifest cannot query eSpeak package"
grep -Fq 'android:name=".SpeechSmokeReceiver"' "$MANIFEST" || \
  fail "SpeechSmokeReceiver is not declared"

grep -Fq "private static final String ACTION = \"$ACCESSIBILITY_TTS_SMOKE_ACTION\";" "$SMOKE_RECEIVER" || \
  fail "speech smoke action drift"
grep -Fq "private static final String ESPEAK_PACKAGE = \"$ESPEAK_PACKAGE\";" "$SMOKE_RECEIVER" || \
  fail "speech smoke eSpeak package drift"
grep -Fq 'Locale.US' "$SMOKE_RECEIVER" || fail "English TTS smoke coverage missing"
grep -Fq 'Locale.FRANCE' "$SMOKE_RECEIVER" || fail "French TTS smoke coverage missing"
grep -Fq 'ACCESSIBLE_TTS_SMOKE=PASS' "$SMOKE_RECEIVER" || fail "TTS PASS marker missing"

grep -Fq 'AccessibilityBootstrap' "$PRODUCT_MK" || fail "AccessibilityBootstrap not included in product"
grep -Fq 'AccessibleTalkBack' "$PRODUCT_MK" || fail "TalkBack not included in product"
grep -Fq 'AccessibleEspeakTts' "$PRODUCT_MK" || fail "eSpeak not included in product"

# Intentional literal code-contract check.
# shellcheck disable=SC2016
grep -Fq '[[ "$TALKBACK_BUILT_PACKAGE" == "$TALKBACK_PACKAGE" ]]' "$BUILD_APPS" || \
  fail "TalkBack APK identity gate missing"
# Intentional literal code-contract check.
# shellcheck disable=SC2016
grep -Fq '[[ "$ESPEAK_BUILT_PACKAGE" == "$ESPEAK_PACKAGE" ]]' "$BUILD_APPS" || \
  fail "eSpeak APK identity gate missing"

grep -Fq 'TALKBACK_BOUND = PASS' "$RUNTIME_VALIDATOR" || fail "bound TalkBack runtime gate missing"
grep -Fq 'TTS_SYNTHESIS_EN_US = PASS' "$RUNTIME_VALIDATOR" || fail "English synthesis runtime gate missing"
grep -Fq 'TTS_SYNTHESIS_FR_FR = PASS' "$RUNTIME_VALIDATOR" || fail "French synthesis runtime gate missing"
grep -Fq 'ACCESSIBILITY_RUNTIME = PASS' "$RUNTIME_VALIDATOR" || fail "runtime PASS marker missing"

echo "ACCESSIBILITY_STATIC_CONTRACT = PASS"
echo "TALKBACK_PACKAGE = $TALKBACK_PACKAGE"
echo "TALKBACK_SERVICE = $TALKBACK_SERVICE"
echo "ESPEAK_PACKAGE = $ESPEAK_PACKAGE"
echo "TTS_SMOKE_ACTION = $ACCESSIBILITY_TTS_SMOKE_ACTION"
