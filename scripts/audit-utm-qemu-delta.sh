#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/utm-upstreams.env"

QEMU_DIR="$UTM_REFERENCE_DIR/qemu"
REPORT="$UTM_REFERENCE_DIR/UTM-QEMU-DELTA.txt"

[[ -d "$QEMU_DIR/.git" ]] || {
  echo "ERROR: UTM QEMU source is not synchronized." >&2
  echo "Run scripts/sync-utm-upstreams.sh first." >&2
  exit 2
}

# The reference checkout begins shallow by design. Deepen enough to recover the
# complete short post-release history so the audit does not silently report
# only the head commit while still diffing the full endpoint trees.
git -C "$QEMU_DIR" fetch --force --depth=64 origin \
  "$UTM_QEMU_RELEASE_REV" "$UTM_QEMU_HEAD_REV"

base="$UTM_QEMU_RELEASE_REV"
head="$UTM_QEMU_HEAD_REV"
commit_count="$(git -C "$QEMU_DIR" rev-list --count "$base..$head")"

{
  echo "UTM QEMU delta audit"
  echo "base=$base ($UTM_QEMU_RELEASE_TAG)"
  echo "head=$head ($UTM_QEMU_HEAD_BRANCH)"
  echo "commit_count=$commit_count"
  echo
  echo "== Commits =="
  git -C "$QEMU_DIR" log --reverse --oneline "$base..$head"
  echo
  echo "== Diff stat =="
  git -C "$QEMU_DIR" diff --stat "$base..$head"
  echo
  echo "== Portable review candidates =="
  git -C "$QEMU_DIR" diff --name-only "$base..$head" \
    | grep -E '^(hw/display/|include/hw/virtio/virtio-gpu\.h$|include/ui/spice-display\.h$|ui/spice-display\.c$|ui/console\.c$|meson\.build$)' \
    || true
  echo
  echo "== Darwin/ARM-specific changes (reference only on Windows) =="
  git -C "$QEMU_DIR" diff --name-only "$base..$head" \
    | grep -E '^(ui/cocoa\.m$|ui/spice-display-metal\.m$|target/arm/|hw/arm/|docs/system/arm/)' \
    || true
} > "$REPORT"

[[ "$commit_count" -ge 1 ]] || {
  echo "ERROR: UTM QEMU delta unexpectedly contains no commits" >&2
  exit 3
}

cat "$REPORT"
echo "UTM_QEMU_DELTA_AUDIT = PASS"
echo "REPORT = $REPORT"
