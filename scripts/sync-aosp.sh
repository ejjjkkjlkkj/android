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

repo manifest -r -o "$ROOT/config/aosp-pinned-manifest.xml"

echo "AOSP_SYNC = PASS"
echo "AOSP_SYNC_ATTEMPTS = $attempt"
echo "AOSP_SYNC_FINAL_JOBS = $jobs"
echo "AOSP_DIR = $AOSP_DIR"
echo "PINNED_MANIFEST = $ROOT/config/aosp-pinned-manifest.xml"
