# Accessible Android x86_64 product with an externally supplied authorized GMS layer.

$(call inherit-product, device/accessibledroid/accessible_x86_64/accessible_android_x86_64.mk)
$(call inherit-product, vendor/accessibledroid/private-gms/gms-product.mk)

PRODUCT_NAME := accessible_android_x86_64_gms
PRODUCT_DEVICE := accessible_x86_64
PRODUCT_BRAND := AccessibleAndroid
PRODUCT_MODEL := Accessible Android 17 GMS x86_64 VM
PRODUCT_MANUFACTURER := Accessible Android Project

# gms-product.mk owns the proprietary package declarations. This repository
# deliberately contains no Google application binaries.
