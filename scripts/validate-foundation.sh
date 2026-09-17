#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[[ -f config/versions.env ]] || fail 'config/versions.env missing'
# shellcheck disable=SC1091
source config/versions.env

required_vars=(
  ANDROID_API_LEVEL AOSP_MANIFEST_URL AOSP_MANIFEST_REF
  ANDROID_KERNEL_URL ANDROID_KERNEL_TAG BUILDROOT_VERSION BUILDROOT_URL
  BUILDROOT_SHA256 GRUB_VERSION TALKBACK_URL TALKBACK_REF TALKBACK_PACKAGE
  TALKBACK_SERVICE ESPEAK_NG_URL ESPEAK_NG_REF ESPEAK_ANDROID_PACKAGE
  ESPEAKUP_URL ESPEAKUP_REF ISO_OUTPUT
)
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || fail "$var is empty"
done
pass 'all pinned version variables are present'

[[ "$ANDROID_API_LEVEL" == '37' ]] || fail 'Android API level is not 37'
[[ "$AOSP_MANIFEST_REF" == android-security-17.0.0_r1 ]] || fail 'unexpected AOSP baseline'
[[ "$ANDROID_KERNEL_TAG" == android17-6.18-2026-09_r3 ]] || fail 'unexpected Android kernel tag'
[[ "$BUILDROOT_VERSION" == '2026.08' ]] || fail 'unexpected Buildroot version'
[[ "$GRUB_VERSION" == '2.14' ]] || fail 'unexpected GRUB version'
pass 'baseline versions match the audited Android 17 foundation'

grep -q 'set default=0' iso/grub/grub.cfg || fail 'GRUB default entry missing'
grep -q 'set timeout=' iso/grub/grub.cfg || fail 'GRUB timeout missing'
grep -q 'terminal_input console serial' iso/grub/grub.cfg || fail 'GRUB serial input mirror missing'
grep -q 'terminal_output console serial' iso/grub/grub.cfg || fail 'GRUB serial output mirror missing'
grep -q 'speakup.synth=soft' iso/grub/grub.cfg || fail 'speech-enabled installer kernel argument missing'
grep -q -- '--hotkey=a' iso/grub/grub.cfg || fail 'accessible installer hotkey missing'
grep -q -- '--hotkey=r' iso/grub/grub.cfg || fail 'recovery hotkey missing'
pass 'GRUB accessibility contract is represented in configuration'

if grep -RIE '\.(qcow2|vdi|vmdk)([^[:alnum:]_]|$)' --exclude-dir=.git . >/dev/null; then
  fail 'VM disk image reference found in clean ISO-only foundation'
fi
pass 'no VM disk image artifact is part of the foundation'

printf 'FOUNDATION RESULT=PASS\n'
