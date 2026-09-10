#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/pc-upstreams.env"

[[ -d "$AOSP_DIR/.repo" ]] || {
  echo "ERROR: AOSP checkout not found at $AOSP_DIR" >&2
  echo "Run scripts/sync-aosp.sh first." >&2
  exit 2
}

sync_repo() {
  local name="$1"
  local url="$2"
  local rev="$3"
  local dest="$4"

  echo "==> $name"
  echo "URL  = $url"
  echo "REV  = $rev"
  echo "DEST = $dest"

  if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
    echo "ERROR: destination exists but is not a Git checkout: $dest" >&2
    exit 3
  fi

  if [[ ! -d "$dest/.git" ]]; then
    mkdir -p "$(dirname "$dest")"
    git clone --filter=blob:none --no-checkout "$url" "$dest"
  fi

  git -C "$dest" remote set-url origin "$url"
  git -C "$dest" fetch --force --depth=1 origin "$rev"
  git -C "$dest" checkout --detach FETCH_HEAD

  local actual
  actual="$(git -C "$dest" rev-parse HEAD)"
  [[ "$actual" == "$rev" ]] || {
    echo "ERROR: $name revision mismatch: expected $rev, got $actual" >&2
    exit 4
  }
}

sync_repo "PC common device layer" "$PC_COMMON_URL" "$PC_COMMON_REV" "$AOSP_DIR/device/generic/common"
sync_repo "PC x86_64 device layer" "$PC_X86_64_URL" "$PC_X86_64_REV" "$AOSP_DIR/device/generic/x86_64"
sync_repo "AAropa installer/initrd" "$PC_INSTALLER_URL" "$PC_INSTALLER_REV" "$AOSP_DIR/bootable/aaropa"

echo "PC_UPSTREAMS = VERIFIED"
echo "AOSP_DIR = $AOSP_DIR"
