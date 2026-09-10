# Common Accessible Android x86_64 product definition shared by AOSP and GMS editions.

$(call inherit-product, device/generic/common/x86_64.mk)
$(call inherit-product, vendor/accessibledroid/product/accessibility.mk)

PRODUCT_DEVICE := accessible_x86_64
PRODUCT_BRAND := AccessibleAndroid
PRODUCT_MANUFACTURER := Accessible Android Project

PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.accessibledroid.vm_reference=qemu \
    ro.vendor.accessibledroid.accessibility_first=true
