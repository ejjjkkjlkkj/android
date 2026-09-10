# Accessible Android x86_64 board configuration.
# The low-level PC hardware definitions are provided by the pinned PC upstream.

include device/generic/x86_64/BoardConfig.mk

# VM-first release policy. Keep userdata sparse-image behavior inherited from
# the PC layer and grow the installed virtual disk at installation/runtime.
TARGET_BOOTLOADER_BOARD_NAME := accessible_x86_64
