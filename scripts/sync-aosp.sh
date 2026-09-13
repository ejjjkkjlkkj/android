#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT"
# shellcheck disable=SC1091
source "$ROOT/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT/config/upstream.env"

SYNC_JOBS="${SYNC_JOBS:-8}"
SYNC_RETRIES="${SYNC_RETRIES:-5}"
SYNC_RETRY_DELAY_SECONDS="${SYNC_RETRY_DELAY_SECONDS:-10}"

if ! [[ "$SYNC_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: SYNC_JOBS must be a positive integer: $SYNC_JOBS" >&2
  exit 2
fi
if ! [[ "$SYNC_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: SYNC_RETRIES must be a positive integer: $SYNC_RETRIES" >&2
  exit 2
fi
if ! [[ "$SYNC_RETRY_DELAY_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SYNC_RETRY_DELAY_SECONDS must be a non-negative integer: $SYNC_RETRY_DELAY_SECONDS" >&2
  exit 2
fi

mkdir -p "$AOSP_DIR"
cd "$AOSP_DIR"

if [[ ! -d .repo ]]; then
  repo init --partial-clone \
    -u "$AOSP_MANIFEST_URL" \
    -b "$AOSP_MANIFEST_BRANCH"
else
  echo "AOSP_SYNC_RESUME = existing .repo workspace"
fi

attempt=1
jobs="$SYNC_JOBS"
while true; do
  echo "AOSP_SYNC_ATTEMPT = $attempt/$SYNC_RETRIES"
  echo "AOSP_SYNC_JOBS = $jobs"

  if repo sync -c -j"$jobs" --fail-fast; then
    break
  fi

  if (( attempt >= SYNC_RETRIES )); then
    echo "ERROR: AOSP repo sync failed after $SYNC_RETRIES attempts." >&2
    exit 1
  fi

  if (( jobs > 2 )); then
    jobs=$((jobs / 2))
    (( jobs < 2 )) && jobs=2
  fi

  attempt=$((attempt + 1))
  echo "AOSP_SYNC_RETRY = preserving downloaded projects; retrying with -j$jobs"
  if (( SYNC_RETRY_DELAY_SECONDS > 0 )); then
    sleep "$SYNC_RETRY_DELAY_SECONDS"
  fi
done

# A successful global repo sync is not sufficient evidence that every existing
# worktree is complete after an interrupted checkout. Detect only tracked files
# that are missing and unresolved index entries; deliberately ignore untracked
# AccessibleAndroid files so the persistent workspace remains non-destructive.
scan_file="$(mktemp)"
# The single quotes are intentional: REPO_PATH and the git commands must be
# evaluated inside each shell spawned by `repo forall`, not by this script.
# shellcheck disable=SC2016
if ! repo forall -c '
  missing="$(git ls-files -d)"
  unmerged="$(git ls-files -u)"
  if test -n "$missing" || test -n "$unmerged"; then
    printf "%s\n" "$REPO_PATH"
  fi
' > "$scan_file"; then
  rm -f "$scan_file"
  echo "ERROR: failed to scan AOSP tracked worktree integrity" >&2
  exit 1
fi
mapfile -t damaged_projects < <(sed '/^[[:space:]]*$/d' "$scan_file" | sort -u)
rm -f "$scan_file"

if (( ${#damaged_projects[@]} > 0 )); then
  echo "AOSP_WORKTREE_REPAIR_COUNT = ${#damaged_projects[@]}"
  for project_path in "${damaged_projects[@]}"; do
    echo "AOSP_WORKTREE_REPAIR = $project_path"
    repo sync -c -j1 --fail-fast --force-checkout "$project_path"
    if [[ -n "$(git -C "$project_path" ls-files -d)" || -n "$(git -C "$project_path" ls-files -u)" ]]; then
      echo "ERROR: AOSP project remains incomplete after repair: $project_path" >&2
      exit 1
    fi
  done
else
  echo "AOSP_WORKTREE_REPAIR_COUNT = 0"
fi

echo "AOSP_TRACKED_WORKTREE_INTEGRITY = PASS"

# libcore is a critical Soong bootstrap input. Keep an explicit fail-closed
# check for the exact corruption already observed on the self-hosted runner.
libcore_required_files=(
  "libcore/JavaLibrary.bp"
  "libcore/NativeCode.bp"
  "libcore/Extras.bp"
)
libcore_repair_required=0
for required_file in "${libcore_required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "AOSP_LIBCORE_MISSING = $required_file" >&2
    libcore_repair_required=1
  fi
done

if (( libcore_repair_required )); then
  echo "AOSP_LIBCORE_REPAIR = targeted repo sync --force-checkout libcore"
  if [[ -d libcore ]]; then
    git -C libcore status --short || true
  fi
  repo sync -c -j1 --fail-fast --force-checkout libcore

  # A repo-managed worktree can remain physically empty after an interrupted
  # checkout even when repo sync reports success. If the manifest revision is
  # present in the local object database, restore the complete tracked libcore
  # tree directly from HEAD. This preserves untracked files and avoids deleting
  # the persistent AOSP workspace.
  echo "AOSP_LIBCORE_RESTORE = git checkout -f HEAD -- ."
  if ! git -C libcore rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    echo "ERROR: libcore HEAD is not a valid commit after repo sync" >&2
    exit 1
  fi
  for required_file in "${libcore_required_files[@]}"; do
    relative_file="${required_file#libcore/}"
    if ! git -C libcore cat-file -e "HEAD:$relative_file"; then
      echo "ERROR: libcore HEAD does not contain required file: $relative_file" >&2
      exit 1
    fi
  done
  git -C libcore checkout -f HEAD -- .
fi

for required_file in "${libcore_required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "ERROR: required libcore file is still missing after targeted repair: $required_file" >&2
    exit 1
  fi
done

if [[ -n "$(git -C libcore ls-files -d)" || -n "$(git -C libcore ls-files -u)" ]]; then
  echo "ERROR: libcore still has missing or unmerged tracked files after repair" >&2
  git -C libcore status --short || true
  exit 1
fi

echo "AOSP_LIBCORE_INTEGRITY = PASS"

repo manifest -r -o "$ROOT/config/aosp-pinned-manifest.xml"

echo "AOSP_SYNC = PASS"
echo "AOSP_SYNC_ATTEMPTS = $attempt"
echo "AOSP_SYNC_FINAL_JOBS = $jobs"
echo "AOSP_DIR = $AOSP_DIR"
echo "PINNED_MANIFEST = $ROOT/config/aosp-pinned-manifest.xml"
