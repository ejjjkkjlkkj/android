# Open Accessible Android x86_64 product.

$(call inherit-product, device/accessibledroid/accessible_x86_64/accessible_android_x86_64_base.mk)

PRODUCT_NAME := accessible_android_x86_64
PRODUCT_MODEL := Accessible Android 17 x86_64 VM

PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.accessibledroid.edition=aosp
