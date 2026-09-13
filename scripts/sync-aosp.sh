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

# A successful global repo sync is not sufficient evidence that every checkout is
# complete. A previous interrupted sync left libcore/Android.bp present while
# files it includes were missing, causing Soong bootstrap to fail later. Validate
# the critical libcore worktree now and repair only that manifest project when
# necessary. libcore is upstream source and is not modified by AccessibleAndroid.
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
fi

for required_file in "${libcore_required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "ERROR: required libcore file is still missing after targeted repair: $required_file" >&2
    exit 1
  fi
done

echo "AOSP_LIBCORE_INTEGRITY = PASS"

repo manifest -r -o "$ROOT/config/aosp-pinned-manifest.xml"

echo "AOSP_SYNC = PASS"
echo "AOSP_SYNC_ATTEMPTS = $attempt"
echo "AOSP_SYNC_FINAL_JOBS = $jobs"
echo "AOSP_DIR = $AOSP_DIR"
echo "PINNED_MANIFEST = $ROOT/config/aosp-pinned-manifest.xml"
