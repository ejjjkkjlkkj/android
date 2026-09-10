# Portable Android 17 userspace hardware stack for the AccessibleAndroid QEMU VM.
# Keep this layer independent from Cuttlefish host protocols (gfxstream/ranchu/vsock):
# the VM exposes standard virtio-gpu DRM, virtio-snd ALSA and USB input devices.

# Generic DRM/KMS composition with minigbm buffers. The HWC3 service carries its
# own init rc and VINTF fragment. minigbm's generic build enables DMA-BUF heaps
# and includes its virtio-gpu backend.
$(call soong_config_set,minigbm,platform,generic)

PRODUCT_PACKAGES += \
    android.hardware.composer.hwc3-service.drm \
    android.hardware.graphics.allocator-service.minigbm \
    mapper.minigbm \
    libEGL_swiftshader \
    libGLESv1_CM_swiftshader \
    libGLESv2_swiftshader

# Render GLES in the guest with SwiftShader while scanout/composition goes
# through DRM/KMS. This avoids coupling AccessibleAndroid to gfxstream/ranchu.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=swiftshader \
    ro.opengles.version=196608 \
    ro.hardware.virtual_device=1

# Android 17 uses the AIDL audio HAL. The default primary implementation talks
# to ALSA card 0/device 0 via TinyALSA, which matches the virtio-snd PCI device
# presented by AccessibleUTM/QEMU.
$(call inherit-product, frameworks/av/services/audiopolicy/audio_policy_config_vendor_1.mk)

PRODUCT_PACKAGES += \
    android.hardware.audio.parameter_parser.example_service \
    com.android.hardware.audio \
    device_google_cuttlefish_shared_config_audio_policy

$(call soong_config_set_bool,cuttlefish_config,use_audio_policy,true)
$(call inherit-product, hardware/interfaces/audio/aidl/default/audio_effects.mk)

PRODUCT_SYSTEM_EXT_PROPERTIES += \
    ro.audio.ihaladaptervendorextension_enabled=true

PRODUCT_PRODUCT_PROPERTIES += \
    aaudio.mmap_policy=2 \
    aaudio.mmap_exclusive_policy=2 \
    aaudio.hw_burst_min_usec=2000

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.audio.output.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.audio.output.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml
