#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/accessibility-upstreams.env"

SRC_ROOT="$ACCESSIBILITY_SRC_DIR"
mkdir -p "$SRC_ROOT"

sync_repo() {
  local name="$1"
  local url="$2"
  local rev="$3"
  local dest="$4"

  if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
    echo "ERROR: $dest exists but is not a Git checkout" >&2
    exit 2
  fi

  if [[ ! -d "$dest/.git" ]]; then
    git clone --filter=blob:none --no-checkout "$url" "$dest"
  fi

  git -C "$dest" remote set-url origin "$url"
  git -C "$dest" fetch --force --depth=1 origin "$rev"
  git -C "$dest" checkout --detach FETCH_HEAD

  local actual
  actual="$(git -C "$dest" rev-parse HEAD)"
  [[ "$actual" == "$rev" ]] || {
    echo "ERROR: $name revision mismatch: expected $rev, got $actual" >&2
    exit 3
  }

  echo "$name = $actual"
}

sync_repo "TALKBACK" "$TALKBACK_URL" "$TALKBACK_REV" "$SRC_ROOT/talkback"
sync_repo "ESPEAK_NG" "$ESPEAK_NG_URL" "$ESPEAK_NG_REV" "$SRC_ROOT/espeak-ng"

echo "ACCESSIBILITY_SOURCES = VERIFIED"
echo "ACCESSIBILITY_SRC_DIR = $ACCESSIBILITY_SRC_DIR"
