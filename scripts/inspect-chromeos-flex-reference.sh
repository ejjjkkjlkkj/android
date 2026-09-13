#!/usr/bin/env bash
set -euo pipefail

URL="${CHROMEOS_FLEX_URL:-https://dl.google.com/chromeos-flex/images/latest.bin.zip}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${FLEX_REFERENCE_DIR:-$ROOT/.work/chromeos-flex-reference}"
ZIP="$WORK/latest.bin.zip"
REPORT="$WORK/report.txt"

mkdir -p "$WORK"

cat > "$REPORT" <<EOF
ChromeOS Flex engineering reference
URL: $URL
Purpose: inspect boot/disk layout only; never redistribute the image.
EOF

if [[ "${DOWNLOAD_FLEX_REFERENCE:-0}" != "1" ]]; then
  cat >> "$REPORT" <<'EOF'
DOWNLOAD_SKIPPED=1
Set DOWNLOAD_FLEX_REFERENCE=1 to explicitly download the external reference image.
EOF
  cat "$REPORT"
  exit 0
fi

for cmd in curl unzip sha256sum file; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $cmd" >&2
    exit 2
  }
done

curl --fail --location --continue-at - --output "$ZIP" "$URL"
sha256sum "$ZIP" | tee -a "$REPORT"
unzip -l "$ZIP" | tee -a "$REPORT"

BIN_NAME="$(unzip -Z1 "$ZIP" | awk '/\.bin$/ {print; exit}')"
[[ -n "$BIN_NAME" ]] || {
  echo "ERROR: no .bin image found in archive" >&2
  exit 3
}

unzip -o "$ZIP" "$BIN_NAME" -d "$WORK"
BIN="$WORK/$BIN_NAME"

file "$BIN" | tee -a "$REPORT"

if command -v fdisk >/dev/null 2>&1; then
  echo "--- fdisk ---" | tee -a "$REPORT"
  fdisk -l "$BIN" | tee -a "$REPORT" || true
fi

if command -v parted >/dev/null 2>&1; then
  echo "--- parted ---" | tee -a "$REPORT"
  parted -s "$BIN" unit s print | tee -a "$REPORT" || true
fi

if command -v cgpt >/dev/null 2>&1; then
  echo "--- cgpt ---" | tee -a "$REPORT"
  cgpt show "$BIN" | tee -a "$REPORT" || true
fi

cat <<EOF | tee -a "$REPORT"
REFERENCE_INSPECTION=PASS
IMAGE=$BIN
REPORT=$REPORT
WARNING=Reference only. Do not copy ChromeOS Flex binaries into Accessible Android artifacts.
EOF
