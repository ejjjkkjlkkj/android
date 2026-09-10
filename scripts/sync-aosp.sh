#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT"
# shellcheck disable=SC1091
source "$ROOT/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT/config/upstream.env"

SYNC_JOBS="${SYNC_JOBS:-8}"

mkdir -p "$AOSP_DIR"
cd "$AOSP_DIR"

if [[ ! -d .repo ]]; then
  repo init --partial-clone \
    -u "$AOSP_MANIFEST_URL" \
    -b "$AOSP_MANIFEST_BRANCH"
fi

repo sync -c -j"$SYNC_JOBS" --fail-fast

repo manifest -r -o "$ROOT/config/aosp-pinned-manifest.xml"

echo "AOSP_SYNC=PASS"
echo "AOSP_DIR=$AOSP_DIR"
echo "PINNED_MANIFEST=$ROOT/config/aosp-pinned-manifest.xml"
