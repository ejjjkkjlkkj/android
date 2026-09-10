# Accessible Android x86_64 product with an externally supplied authorized GMS layer.

$(call inherit-product, device/accessibledroid/accessible_x86_64/accessible_android_x86_64_base.mk)
$(call inherit-product, vendor/accessibledroid/private-gms/gms-product.mk)

PRODUCT_NAME := accessible_android_x86_64_gms
PRODUCT_MODEL := Accessible Android 17 GMS x86_64 VM

PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.accessibledroid.edition=gms

# gms-product.mk owns the proprietary package declarations. This repository
# deliberately contains no Google application binaries.
