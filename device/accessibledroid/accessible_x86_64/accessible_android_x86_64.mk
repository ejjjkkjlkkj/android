# Base Accessible Android x86_64 product.

$(call inherit-product, device/generic/common/x86_64.mk)
$(call inherit-product-if-exists, vendor/accessibledroid/product/accessibility.mk)

PRODUCT_NAME := accessible_android_x86_64
PRODUCT_DEVICE := accessible_x86_64
PRODUCT_BRAND := AccessibleAndroid
PRODUCT_MODEL := Accessible Android 17 x86_64 VM
PRODUCT_MANUFACTURER := Accessible Android Project

PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.accessibledroid.edition=aosp \
    ro.vendor.accessibledroid.vm_reference=qemu
