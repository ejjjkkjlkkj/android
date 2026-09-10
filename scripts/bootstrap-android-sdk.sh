#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/toolchain.env"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: this bootstrap currently targets the Linux AOSP build host." >&2
  exit 2
fi

for command in curl unzip java sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $command" >&2
    exit 3
  }
done

SDK_ROOT="$ANDROID_SDK_ROOT"
TOOLS_ROOT="$ROOT_DIR/.work/tools"
GRADLE_ROOT="$TOOLS_ROOT/gradle-$TALKBACK_GRADLE_VERSION"
TMP_ROOT="$ROOT_DIR/.work/tmp/android-sdk-bootstrap"
CMDLINE_ZIP="$TMP_ROOT/commandlinetools.zip"
CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_REV}_latest.zip"

mkdir -p "$SDK_ROOT/cmdline-tools" "$TOOLS_ROOT" "$TMP_ROOT"

if [[ ! -x "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]]; then
  echo "==> Download Android command-line tools $ANDROID_CMDLINE_TOOLS_REV"
  curl --fail --location --retry 3 "$CMDLINE_URL" --output "$CMDLINE_ZIP"
  rm -rf "$TMP_ROOT/unpacked" "$SDK_ROOT/cmdline-tools/latest"
  mkdir -p "$TMP_ROOT/unpacked" "$SDK_ROOT/cmdline-tools/latest"
  unzip -q "$CMDLINE_ZIP" -d "$TMP_ROOT/unpacked"
  cp -a "$TMP_ROOT/unpacked/cmdline-tools/." "$SDK_ROOT/cmdline-tools/latest/"
fi

SDKMANAGER="$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export PATH="$SDK_ROOT/platform-tools:$SDK_ROOT/cmdline-tools/latest/bin:$PATH"

echo "==> Accept Android SDK licenses"
yes | "$SDKMANAGER" --sdk_root="$SDK_ROOT" --licenses >/dev/null || true

echo "==> Install Android SDK components"
"$SDKMANAGER" --sdk_root="$SDK_ROOT" \
  "platform-tools" \
  "platforms;$ANDROID_COMPILE_PLATFORM" \
  "build-tools;$ANDROID_BUILD_TOOLS_VERSION" \
  "ndk;$ANDROID_NDK_VERSION" \
  "cmake;$ANDROID_CMAKE_VERSION"

if [[ ! -x "$GRADLE_ROOT/bin/gradle" ]]; then
  GRADLE_ZIP="$TMP_ROOT/gradle-${TALKBACK_GRADLE_VERSION}-bin.zip"
  GRADLE_SHA="$TMP_ROOT/gradle-${TALKBACK_GRADLE_VERSION}-bin.zip.sha256"
  GRADLE_URL="https://services.gradle.org/distributions/gradle-${TALKBACK_GRADLE_VERSION}-bin.zip"
  GRADLE_SHA_URL="$GRADLE_URL.sha256"

  echo "==> Download Gradle $TALKBACK_GRADLE_VERSION"
  curl --fail --location --retry 3 "$GRADLE_URL" --output "$GRADLE_ZIP"
  curl --fail --location --retry 3 "$GRADLE_SHA_URL" --output "$GRADLE_SHA"
  printf '%s  %s\n' "$(tr -d '\r\n' < "$GRADLE_SHA")" "$GRADLE_ZIP" | sha256sum --check --status

  rm -rf "$GRADLE_ROOT"
  unzip -q "$GRADLE_ZIP" -d "$TOOLS_ROOT"
fi

"$SDKMANAGER" --sdk_root="$SDK_ROOT" --list_installed
"$GRADLE_ROOT/bin/gradle" --version

echo "ANDROID_SDK_BOOTSTRAP = PASS"
echo "ANDROID_SDK_ROOT = $SDK_ROOT"
echo "TALKBACK_GRADLE = $GRADLE_ROOT/bin/gradle"
