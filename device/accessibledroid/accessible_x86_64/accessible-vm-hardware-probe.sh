#!/system/bin/sh
set -eu

SERIAL=/dev/ttyS0

emit() {
    printf '%s\n' "$1" > "$SERIAL"
}

fail() {
    emit "ACCESSIBLE_ANDROID_GUEST_HARDWARE=FAIL:$1"
    exit 1
}

require_path() {
    path="$1"
    marker="$2"
    [ -e "$path" ] || fail "$marker"
    emit "ACCESSIBLE_ANDROID_${marker}=PASS"
}

# Boot-critical fixed PCI topology shared with AccessibleUTM/QEMU.
require_path /sys/bus/pci/devices/0000:00:06.0 OS_DISK_PCI
require_path /sys/bus/pci/devices/0000:00:07.0 RNG_PCI
require_path /sys/bus/pci/devices/0000:00:08.0 NET_PCI

# Graphics must reach a real DRM/KMS device inside Android.
require_path /dev/dri/card0 DRM_DEVICE

# Audio must be backed by the virtio-snd card presented by QEMU.
[ -r /proc/asound/cards ] || fail AUDIO_PROC
if ! grep -Eiq 'virtio' /proc/asound/cards; then
    fail AUDIO_VIRTIO
fi
emit ACCESSIBLE_ANDROID_AUDIO_VIRTIO=PASS

# The accessible VM contract requires both keyboard and absolute/pointer input.
[ -r /proc/bus/input/devices ] || fail INPUT_PROC
if ! grep -Eiq 'keyboard|kbd' /proc/bus/input/devices; then
    fail INPUT_KEYBOARD
fi
emit ACCESSIBLE_ANDROID_INPUT_KEYBOARD=PASS
if ! grep -Eiq 'tablet|mouse|touch' /proc/bus/input/devices; then
    fail INPUT_POINTER
fi
emit ACCESSIBLE_ANDROID_INPUT_POINTER=PASS

# virtio-net is fixed at PCI 00:08.0; require a usable non-loopback interface.
if ! grep -Eq '^[[:space:]]*(eth|en)[[:alnum:]_.:-]*:' /proc/net/dev; then
    fail NETWORK_INTERFACE
fi
emit ACCESSIBLE_ANDROID_NETWORK_INTERFACE=PASS

emit ACCESSIBLE_ANDROID_GUEST_HARDWARE=PASS
