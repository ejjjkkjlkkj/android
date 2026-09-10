# Accessibility is part of the base operating system for every edition.
PRODUCT_PACKAGES += \
    AccessibilityBootstrap \
    AccessibleTalkBack \
    AccessibleEspeakTts

PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.accessibledroid.accessibility_required=true \
    ro.vendor.accessibledroid.offline_tts_required=true
