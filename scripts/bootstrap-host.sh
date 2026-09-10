#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: full AOSP builds require a 64-bit Linux host." >&2
  exit 2
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "WARNING: the primary build path is validated on x86_64 Linux." >&2
fi

if [[ ! -e /dev/kvm ]]; then
  echo "WARNING: /dev/kvm is absent. Building is possible, but running Cuttlefish locally will require KVM." >&2
fi

sudo apt-get update
sudo apt-get install -y \
  git-core gnupg flex bison build-essential zip curl zlib1g-dev \
  libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev \
  libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig repo

repo version

echo "HOST_BOOTSTRAP=PASS"
echo "NOTE: AOSP recommends at least 400 GB free disk and 64 GB RAM for current full builds."
