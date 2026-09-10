# Common Accessible Android x86_64 product definition shared by AOSP and GMS editions.
# Keep the Android 17 platform userspace based on AOSP. PC/Bliss repositories are
# engineering references only and must never replace these platform product layers.

# 64/32-bit x86_64 runtime and GSI-style system image.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)

# Full handheld/phone framework split across system_ext and product, following
# the Android 17 AOSP virtual-phone composition rather than the old Android-x86
# product inheritance chain.
PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := relaxed
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/window_extensions.mk)

# Modern platform behavior used by an Android 17 GKI device.
$(call inherit-product, $(SRC_TARGET_DIR)/product/languages_full.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/updatable_apex.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/userspace_reboot.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_ramdisk.mk)
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# First-stage mount contract for the virtio installation disk. GKI first-stage
# init reads the device fstab from vendor_boot; keep a second copy in /vendor for
# diagnostics and recovery tooling after the real vendor partition is mounted.
PRODUCT_COPY_FILES += \
    device/accessibledroid/accessible_x86_64/fstab.accessible_x86_64:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/first_stage_ramdisk/fstab.accessible_x86_64 \
    device/accessibledroid/accessible_x86_64/fstab.accessible_x86_64:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.accessible_x86_64 \
    device/accessibledroid/accessible_x86_64/init.accessibledroid.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.accessibledroid.rc

# Accessibility is part of the base system and is independent of GMS.
$(call inherit-product, vendor/accessibledroid/product/accessibility.mk)

PRODUCT_DEVICE := accessible_x86_64
PRODUCT_BRAND := AccessibleAndroid
PRODUCT_MANUFACTURER := Accessible Android Project
PRODUCT_CHARACTERISTICS := nosdcard

PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.accessibledroid.vm_reference=qemu \
    ro.vendor.accessibledroid.accessibility_first=true
