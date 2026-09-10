#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bad_files="$(find . -path './.git' -prune -o -type f \( -iname '*.apk' -o -iname '*.apex' -o -iname '*.xapk' -o -iname '*.apks' \) -print)"

if [[ -n "$bad_files" ]]; then
  echo "ERROR: packaged Android binaries are committed in the orchestration repository:" >&2
  printf '%s\n' "$bad_files" >&2
  echo "Keep proprietary GMS inputs outside the repository. Open-source packages should be built from source by the Android product tree." >&2
  exit 2
fi

echo "PROPRIETARY_BINARY_GUARD = PASS"
