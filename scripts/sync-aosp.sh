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
# worktree is complete after an interrupted checkout. Detect tracked files that
# are missing and unresolved index entries. Deliberately ignore untracked
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

aosp_repair_happened=0
if (( ${#damaged_projects[@]} > 0 )); then
  echo "AOSP_WORKTREE_REPAIR_COUNT = ${#damaged_projects[@]}"
  for project_path in "${damaged_projects[@]}"; do
    echo "AOSP_WORKTREE_REPAIR = $project_path"
    repo sync -c -j1 --fail-fast --force-checkout "$project_path"
    if [[ -n "$(git -C "$project_path" ls-files -d)" || -n "$(git -C "$project_path" ls-files -u)" ]]; then
      echo "ERROR: AOSP project remains incomplete after repair: $project_path" >&2
      exit 1
    fi
    aosp_repair_happened=1
  done
else
  echo "AOSP_WORKTREE_REPAIR_COUNT = 0"
fi

echo "AOSP_TRACKED_WORKTREE_INTEGRITY = PASS"

# Some interrupted/self-hosted checkouts can hide missing tracked files behind
# skip-worktree/sparse state, in which case `git ls-files -d` reports nothing.
# Verify build-critical files explicitly and restore the complete project tree
# from the manifest-pinned HEAD if any of them are physically absent.
repair_critical_project() {
  local project_path="$1"
  shift
  local required_file
  local repair_required=0

  if [[ ! -d "$project_path/.git" && ! -f "$project_path/.git" ]]; then
    echo "ERROR: critical AOSP project worktree is missing: $project_path" >&2
    exit 1
  fi
  if ! git -C "$project_path" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    echo "ERROR: $project_path HEAD is not a valid commit" >&2
    exit 1
  fi

  for required_file in "$@"; do
    if [[ ! -f "$project_path/$required_file" ]]; then
      echo "AOSP_CRITICAL_FILE_MISSING = $project_path/$required_file" >&2
      repair_required=1
    fi
  done

  if (( repair_required )); then
    echo "AOSP_CRITICAL_PROJECT_REPAIR = $project_path"
    repo sync -c -j1 --fail-fast --force-checkout "$project_path"

    # A persistent runner may retain sparse/skip-worktree bits from an earlier
    # interrupted operation. Disable sparse checkout when active, then bypass
    # skip-worktree bits explicitly while restoring every tracked path.
    if [[ "$(git -C "$project_path" config --bool core.sparseCheckout 2>/dev/null || true)" == "true" ]]; then
      echo "AOSP_SPARSE_CHECKOUT_DISABLE = $project_path"
      git -C "$project_path" sparse-checkout disable
    fi

    for required_file in "$@"; do
      if ! git -C "$project_path" cat-file -e "HEAD:$required_file"; then
        echo "ERROR: $project_path HEAD does not contain required file: $required_file" >&2
        exit 1
      fi
    done

    echo "AOSP_CRITICAL_PROJECT_RESTORE = git checkout HEAD -- $project_path"
    git -C "$project_path" checkout --ignore-skip-worktree-bits -f HEAD -- .
    aosp_repair_happened=1
  fi

  for required_file in "$@"; do
    if [[ ! -f "$project_path/$required_file" ]]; then
      echo "ERROR: critical file remains missing after repair: $project_path/$required_file" >&2
      exit 1
    fi
  done

  if [[ -n "$(git -C "$project_path" ls-files -d)" || -n "$(git -C "$project_path" ls-files -u)" ]]; then
    echo "ERROR: critical AOSP project remains incomplete after repair: $project_path" >&2
    git -C "$project_path" status --short || true
    exit 1
  fi
}

repair_critical_project "libcore" \
  "JavaLibrary.bp" \
  "NativeCode.bp" \
  "Extras.bp"
echo "AOSP_LIBCORE_INTEGRITY = PASS"

# Every undefined module observed in gate attempt 4 is defined by one of these
# frameworks/base Blueprint files. Their absence proves a physically incomplete
# worktree even when `repo sync` and the generic deleted-file scan both pass.
repair_critical_project "frameworks/base" \
  "AconfigFlags.bp" \
  "packages/Android.bp" \
  "packages/SettingsLib/Android.bp" \
  "packages/SystemUI/Android.bp" \
  "libs/WindowManager/Shell/Android.bp"
echo "AOSP_FRAMEWORKS_BASE_INTEGRITY = PASS"

# Do not let Soong reuse module-path metadata produced while a critical AOSP
# worktree was incomplete. Keep the expensive output tree otherwise intact.
if (( aosp_repair_happened )); then
  rm -rf out/soong out/.module_paths
  echo "AOSP_SOONG_STATE_RESET = PASS"
else
  echo "AOSP_SOONG_STATE_RESET = NOT_NEEDED"
fi

repo manifest -r -o "$ROOT/config/aosp-pinned-manifest.xml"

echo "AOSP_SYNC = PASS"
echo "AOSP_SYNC_ATTEMPTS = $attempt"
echo "AOSP_SYNC_FINAL_JOBS = $jobs"
echo "AOSP_DIR = $AOSP_DIR"
echo "PINNED_MANIFEST = $ROOT/config/aosp-pinned-manifest.xml"
