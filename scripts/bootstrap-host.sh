#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: full AOSP builds require a 64-bit Linux host." >&2
  exit 2
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "WARNING: the primary build path is validated on x86_64 Linux." >&2
fi

if [[ -e /dev/kvm ]]; then
  echo "KVM = AVAILABLE"
else
  echo "WARNING: /dev/kvm is absent. QEMU runtime tests will use TCG unless KVM becomes available." >&2
fi

sudo apt-get update
sudo apt-get install -y \
  git-core gnupg flex bison build-essential zip curl zlib1g-dev \
  libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev \
  libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig repo rsync \
  openjdk-17-jdk-headless \
  xorriso grub-pc-bin grub-efi-amd64-bin syslinux-common isolinux \
  mtools dosfstools e2fsprogs squashfs-tools gdisk parted \
  qemu-system-x86 qemu-utils ovmf

repo version
java -version
qemu-system-x86_64 --version
qemu-img --version
xorriso -version | head -n 1

echo "HOST_BOOTSTRAP=PASS"
echo "NOTE: full current AOSP builds require a high-capacity Linux builder; lightweight GitHub-hosted runners are for validation, not the full platform build."
