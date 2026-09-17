#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[[ -f config/versions.env ]] || fail 'config/versions.env missing'
[[ -f docs/VISUAL-AND-SCREENREADER-POLICY.md ]] || fail 'visual + screen-reader policy missing'
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
grep -q 'set timeout_style=menu' iso/grub/grub.cfg || fail 'visible GRUB menu is not guaranteed'
grep -q 'terminal_input console serial' iso/grub/grub.cfg || fail 'GRUB local + serial input missing'
grep -q 'terminal_output console serial' iso/grub/grub.cfg || fail 'GRUB visible console + serial output missing'
grep -q 'speakup.synth=soft' iso/grub/grub.cfg || fail 'screen-reader installer kernel argument missing'
grep -q 'accessibleandroid.visual=1' iso/grub/grub.cfg || fail 'visual installer path not explicitly enabled'
grep -q 'accessibleandroid.screenreader=1' iso/grub/grub.cfg || fail 'screen-reader path not explicitly enabled'
grep -q -- '--hotkey=a' iso/grub/grub.cfg || fail 'accessible installer hotkey missing'
grep -q -- '--hotkey=r' iso/grub/grub.cfg || fail 'recovery hotkey missing'
pass 'GRUB preserves visible UI and adds parallel accessibility channels'

grep -q 'Accessibility is additive' docs/VISUAL-AND-SCREENREADER-POLICY.md \
  || fail 'additive accessibility policy not found'
grep -q 'visible text/TUI installer interface' docs/ACCESSIBILITY-BOOT-CONTRACT.md \
  || fail 'visible installer requirement missing'
grep -q 'screen-reader' installer/README.md \
  || fail 'installer screen-reader requirement missing'
pass 'visual + screen-reader parity policy is represented'

if find . -type f \( -name '*.qcow2' -o -name '*.vdi' -o -name '*.vmdk' \) -print -quit | grep -q .; then
  fail 'VM disk image artifact found in clean ISO-only foundation'
fi
pass 'no VM disk image artifact is part of the foundation'

printf 'FOUNDATION RESULT=PASS\n'
