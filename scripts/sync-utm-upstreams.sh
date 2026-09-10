#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/workspace.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/config/utm-upstreams.env"

UTM_DIR="$UTM_REFERENCE_DIR/UTM"
UTM_QEMU_DIR="$UTM_REFERENCE_DIR/qemu"
PROVENANCE="$UTM_REFERENCE_DIR/PROVENANCE.txt"

for command_name in git sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 2
  }
done

sync_exact() {
  local name="$1"
  local url="$2"
  local rev="$3"
  local dest="$4"

  echo "==> Sync $name"
  echo "URL = $url"
  echo "REV = $rev"

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

rm -f "$PROVENANCE"
mkdir -p "$UTM_REFERENCE_DIR"

sync_exact "UTM frontend/reference" "$UTM_REPOSITORY" "$UTM_REV" "$UTM_DIR"
sync_exact "UTM QEMU fork" "$UTM_QEMU_REPOSITORY" "$UTM_QEMU_HEAD_REV" "$UTM_QEMU_DIR"

[[ -f "$UTM_DIR/LICENSE" ]] || {
  echo "ERROR: UTM LICENSE is missing" >&2
  exit 5
}
grep -Fq 'Apache License' "$UTM_DIR/LICENSE" || {
  echo "ERROR: UTM license no longer matches the expected Apache-2.0 source" >&2
  exit 6
}

[[ -f "$UTM_DIR/Documentation/Architecture.md" ]] || {
  echo "ERROR: pinned UTM architecture documentation is missing" >&2
  exit 7
}
[[ -f "$UTM_DIR/patches/sources" ]] || {
  echo "ERROR: pinned UTM dependency source manifest is missing" >&2
  exit 8
}

grep -Fq "$UTM_QEMU_RELEASE_TAG" "$UTM_DIR/patches/sources" || {
  echo "ERROR: pinned UTM source no longer references expected QEMU release $UTM_QEMU_RELEASE_TAG" >&2
  exit 9
}

{
  echo "UTM_REPOSITORY=$UTM_REPOSITORY"
  echo "UTM_REV=$(git -C "$UTM_DIR" rev-parse HEAD)"
  echo "UTM_VERSION=$UTM_VERSION"
  echo "UTM_LICENSE=$UTM_LICENSE"
  echo "UTM_QEMU_REPOSITORY=$UTM_QEMU_REPOSITORY"
  echo "UTM_QEMU_RELEASE_TAG=$UTM_QEMU_RELEASE_TAG"
  echo "UTM_QEMU_RELEASE_REV=$UTM_QEMU_RELEASE_REV"
  echo "UTM_QEMU_HEAD_BRANCH=$UTM_QEMU_HEAD_BRANCH"
  echo "UTM_QEMU_HEAD_REV=$(git -C "$UTM_QEMU_DIR" rev-parse HEAD)"
  echo "UTM_LICENSE_SHA256=$(sha256sum "$UTM_DIR/LICENSE" | awk '{print $1}')"
  echo "UTM_ARCHITECTURE_SHA256=$(sha256sum "$UTM_DIR/Documentation/Architecture.md" | awk '{print $1}')"
} > "$PROVENANCE"

cat "$PROVENANCE"
echo "UTM_REFERENCE_SYNC = PASS"
echo "NOTE: UTM/UTM-QEMU remain isolated under .work and are reference sources only."
