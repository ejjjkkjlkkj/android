#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/pc-upstreams.env"

sync_repo() {
  local name="$1"
  local url="$2"
  local rev="$3"
  local dest="$4"

  case "$dest" in
    "$AOSP_DIR"|"$AOSP_DIR"/*)
      echo "ERROR: PC reference checkout must never replace files inside AOSP_DIR: $dest" >&2
      exit 2
      ;;
  esac

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

mkdir -p "$PC_REFERENCE_DIR"
sync_repo "PC common device reference" "$PC_COMMON_URL" "$PC_COMMON_REV" "$PC_REFERENCE_DIR/device_generic_common"
sync_repo "PC x86_64 device reference" "$PC_X86_64_URL" "$PC_X86_64_REV" "$PC_REFERENCE_DIR/device_generic_x86_64"
sync_repo "AAropa installer/initrd reference" "$PC_INSTALLER_URL" "$PC_INSTALLER_REV" "$PC_REFERENCE_DIR/bootable_aaropa"

echo "PC_UPSTREAMS = VERIFIED_REFERENCE_ONLY"
echo "PC_REFERENCE_DIR = $PC_REFERENCE_DIR"
echo "AOSP tree was not modified by this script."
