#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/upstream.env"

PRODUCT="${PRODUCT_NAME:-accessible_android_x86_64}"
export PRODUCT_NAME="$PRODUCT"

# Build only Android-native images and the canonical target-files package.
# Android-x86/AAropa's iso_img target is intentionally not part of this project.
"$ROOT_DIR/scripts/build-android-images.sh"

# Package the current non-destructive BIOS/UEFI installer-preview medium from
# those images. The upcoming installer engine will consume this exact payload
# format, so ISO transport and disk installation cannot drift apart.
"$ROOT_DIR/scripts/package-android-payload-iso.sh"

PRODUCT_OUT="${OUT_DIR:-$AOSP_DIR/out/target/product/$PRODUCT}"
find "$PRODUCT_OUT" -maxdepth 2 -type f -name '*.img' -print | sort
find "$VM_ARTIFACT_DIR" -maxdepth 1 -type f \
  \( -name 'AccessibleAndroid-17-*.iso' -o -name 'AccessibleAndroid-17-*.iso.sha256' \) \
  -print | sort

echo "PC_ISO_PIPELINE = PASS"
echo "NOTE = installer preview is bootable and non-destructive until GPT install engine validation is complete"
