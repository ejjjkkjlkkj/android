#!/system/bin/sh
set -eu

SERIAL=/dev/ttyS0
TALKBACK_PACKAGE=com.google.android.accessibility.talkback
TALKBACK_COMPONENT=com.google.android.accessibility.talkback/com.google.android.marvin.talkback.TalkBackService
ESPEAK_PACKAGE=com.reecedunn.espeak
ACCESSIBILITY_WAIT_SECONDS=45

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

# Audio must be backed by the virtio-snd card presented by QEMU and Android's
# framework audio services must be alive before accessibility speech is trusted.
[ -r /proc/asound/cards ] || fail AUDIO_PROC
if ! grep -Eiq 'virtio' /proc/asound/cards; then
    fail AUDIO_VIRTIO
fi
emit ACCESSIBLE_ANDROID_AUDIO_VIRTIO=PASS

if ! service check audio 2>/dev/null | grep -Fq found; then
    fail AUDIO_SERVICE
fi
if ! dumpsys media.audio_flinger >/dev/null 2>&1; then
    fail AUDIO_FLINGER
fi
emit ACCESSIBLE_ANDROID_AUDIO_FRAMEWORK=PASS

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

# AccessibilityBootstrap may finish just after sys.boot_completed. Wait for the
# exact TalkBack + offline eSpeak configuration instead of racing first boot.
if ! cmd package path "$TALKBACK_PACKAGE" >/dev/null 2>&1; then
    fail TALKBACK_PACKAGE
fi
if ! cmd package path "$ESPEAK_PACKAGE" >/dev/null 2>&1; then
    fail ESPEAK_PACKAGE
fi
emit ACCESSIBLE_ANDROID_ACCESSIBILITY_PACKAGES=PASS

attempt=0
accessibility_ready=0
while [ "$attempt" -lt "$ACCESSIBILITY_WAIT_SECONDS" ]; do
    accessibility_enabled="$(settings get secure accessibility_enabled 2>/dev/null || true)"
    enabled_services="$(settings get secure enabled_accessibility_services 2>/dev/null || true)"
    default_tts="$(settings get secure tts_default_synth 2>/dev/null || true)"

    if [ "$accessibility_enabled" = "1" ] \
        && printf '%s\n' "$enabled_services" | grep -Fq "$TALKBACK_COMPONENT" \
        && [ "$default_tts" = "$ESPEAK_PACKAGE" ]; then
        accessibility_ready=1
        break
    fi

    attempt=$((attempt + 1))
    sleep 1
done

[ "$accessibility_ready" -eq 1 ] || fail ACCESSIBILITY_BOOTSTRAP

if ! dumpsys accessibility 2>/dev/null | grep -Fq "$TALKBACK_PACKAGE"; then
    fail TALKBACK_RUNTIME
fi
emit ACCESSIBLE_ANDROID_TALKBACK=PASS
emit ACCESSIBLE_ANDROID_OFFLINE_TTS=PASS
emit ACCESSIBLE_ANDROID_ACCESSIBILITY_STACK=PASS

emit ACCESSIBLE_ANDROID_GUEST_HARDWARE=PASS
