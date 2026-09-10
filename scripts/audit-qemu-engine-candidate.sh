#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/qemu-engine.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/utm-upstreams.env"

SOURCE_DIR="$QEMU_ENGINE_DIR/source"
REPORT="$QEMU_ENGINE_DIR/CANDIDATE-BLOB-UNMAP.txt"

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git is required" >&2
  exit 2
}

mkdir -p "$QEMU_ENGINE_DIR"

if [[ -e "$SOURCE_DIR" && ! -d "$SOURCE_DIR/.git" ]]; then
  echo "ERROR: QEMU engine source path is not a Git checkout: $SOURCE_DIR" >&2
  exit 3
fi

# Use a plain repository rather than a promisor/partial clone. A partial clone
# associates missing objects with one remote and can incorrectly ask official
# QEMU for objects that exist only in the UTM fork during a cherry-pick audit.
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  mkdir -p "$SOURCE_DIR"
  git -C "$SOURCE_DIR" init
  git -C "$SOURCE_DIR" remote add origin "$QEMU_UPSTREAM_REPOSITORY"
fi

git -C "$SOURCE_DIR" remote set-url origin "$QEMU_UPSTREAM_REPOSITORY"
git -C "$SOURCE_DIR" fetch --force --depth=1 origin "$QEMU_UPSTREAM_REV"
git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD

actual="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
[[ "$actual" == "$QEMU_UPSTREAM_REV" ]] || {
  echo "ERROR: QEMU baseline mismatch: expected $QEMU_UPSTREAM_REV, got $actual" >&2
  exit 4
}

if git -C "$SOURCE_DIR" remote get-url utm >/dev/null 2>&1; then
  git -C "$SOURCE_DIR" remote set-url utm "$UTM_QEMU_REPOSITORY"
else
  git -C "$SOURCE_DIR" remote add utm "$UTM_QEMU_REPOSITORY"
fi

# Depth 2 is required because cherry-pick computes the candidate diff against
# its parent. Fetch both from the UTM remote so object ownership is unambiguous.
git -C "$SOURCE_DIR" fetch --force --depth=2 utm "$QEMU_UTM_CANDIDATE_BLOB_UNMAP_REV"

{
  echo "AccessibleQEMU Engine candidate audit"
  echo "baseline_tag=$QEMU_UPSTREAM_TAG"
  echo "baseline_rev=$QEMU_UPSTREAM_REV"
  echo "utm_candidate=$QEMU_UTM_CANDIDATE_BLOB_UNMAP_REV"
  echo "configured_state=$QEMU_UTM_CANDIDATE_BLOB_UNMAP_STATE"
  echo
} > "$REPORT"

set +e
git -C "$SOURCE_DIR" cherry-pick --no-commit "$QEMU_UTM_CANDIDATE_BLOB_UNMAP_REV" \
  >"$QEMU_ENGINE_DIR/cherry-pick.stdout" 2>"$QEMU_ENGINE_DIR/cherry-pick.stderr"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  {
    echo "automatic_apply=PASS"
    echo "changed_files:"
    git -C "$SOURCE_DIR" diff --name-only | sed 's/^/  /'
    echo
    echo "NOTE: automatic application is not acceptance. QEMU build and targeted virtio-gpu tests are still required."
  } >> "$REPORT"
  git -C "$SOURCE_DIR" reset --hard "$QEMU_UPSTREAM_REV" >/dev/null
else
  {
    echo "automatic_apply=NEEDS_MANUAL_PORT"
    echo "conflicted_files:"
    git -C "$SOURCE_DIR" diff --name-only --diff-filter=U | sed 's/^/  /'
    echo
    echo "cherry_pick_stderr:"
    sed 's/^/  /' "$QEMU_ENGINE_DIR/cherry-pick.stderr"
    echo
    echo "NOTE: the candidate was written for UTM QEMU 10.0.x. Conflicts are expected if QEMU 11.1.1 already contains related upstream changes."
  } >> "$REPORT"
  git -C "$SOURCE_DIR" cherry-pick --abort >/dev/null 2>&1 || true
  git -C "$SOURCE_DIR" reset --hard "$QEMU_UPSTREAM_REV" >/dev/null
fi

cat "$REPORT"
echo "QEMU_ENGINE_CANDIDATE_AUDIT = PASS"
