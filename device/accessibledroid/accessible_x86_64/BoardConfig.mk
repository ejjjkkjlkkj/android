# Accessible Android x86_64 board configuration.
# The low-level PC hardware definitions are provided by the pinned PC upstream
# while the kernel itself comes from the official Android 17 GKI 6.18 tree.

include device/generic/x86_64/BoardConfig.mk

# The generic AOSP x86_64 board disables a kernel because it is not a physical
# boot target. AccessibleAndroid is a real bootable VM/PC product, so explicitly
# restore a kernel target and stage the Kleaf-built x86_64 bzImage as a prebuilt.
TARGET_NO_KERNEL := false
TARGET_PREBUILT_KERNEL := device/accessibledroid/accessible_x86_64/prebuilt/kernel

# VM-first release policy. Keep userdata sparse-image behavior inherited from
# the PC layer and grow the installed virtual disk at installation/runtime.
TARGET_BOOTLOADER_BOARD_NAME := accessible_x86_64
