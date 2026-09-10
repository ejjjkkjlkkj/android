# AccessibleAndroid Android 17 x86_64 board configuration.
# Use AOSP's official x86_64 architecture baseline. External PC projects are
# reference material only and must not replace the AOSP device/generic tree.

include device/generic/x86_64/BoardConfig.mk

LOCAL_ACCESSIBLE_DEVICE := device/accessibledroid/accessible_x86_64

# Real bootable GKI target. device/generic/x86_64 is intentionally kernel-less,
# so AccessibleAndroid stages the Android 17 virtual-device bzImage explicitly.
TARGET_NO_KERNEL := false
TARGET_PREBUILT_KERNEL := $(LOCAL_ACCESSIBLE_DEVICE)/prebuilt/kernel
TARGET_BOOTLOADER_BOARD_NAME := accessible_x86_64
BOARD_USES_GENERIC_KERNEL_IMAGE := true
BOARD_USES_RECOVERY_AS_BOOT :=
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE :=
BOARD_MOVE_GSI_AVB_KEYS_TO_VENDOR_BOOT := true

# Android 13+ GKI layout: boot is kernel-only, the generic ramdisk is in
# init_boot, and device/VM first-stage modules live in vendor_boot.
BOARD_BOOT_HEADER_VERSION := 4
BOARD_INIT_BOOT_HEADER_VERSION := 4
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
BOARD_MKBOOTIMG_INIT_ARGS += --header_version $(BOARD_INIT_BOOT_HEADER_VERSION)
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_INIT_BOOT_IMAGE_PARTITION_SIZE := 8388608
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_RAMDISK_USE_LZ4 := true

# Serial output is a deterministic accessibility/debugging fallback before the
# Android speech stack is available. QEMU exposes the same serial stream to the
# host-side AccessibleQEMU diagnostics.
BOARD_KERNEL_CMDLINE += console=tty0 console=ttyS0,115200n8
BOARD_KERNEL_CMDLINE += panic=-1 printk.devkmsg=on 8250.nr_uarts=1 loop.max_part=7
BOARD_BOOTCONFIG += androidboot.hardware=accessible_x86_64
BOARD_BOOTCONFIG += androidboot.boot_devices=pci0000:00

# Android 17 virtual-device kernel modules staged by scripts/stage-kernel.sh.
KERNEL_MODULE_DIR := $(LOCAL_ACCESSIBLE_DEVICE)/prebuilt/modules
KERNEL_MODULES := $(wildcard $(KERNEL_MODULE_DIR)/*.ko)

# Keep first-stage init small: only modules which can be required to discover
# the virtio system disk and provide entropy are copied to vendor_boot.
ACCESSIBLE_FIRST_STAGE_MODULE_NAMES := \
    virtio_pci_modern_dev.ko \
    virtio_pci.ko \
    virtio_blk.ko \
    virtio-rng.ko
ACCESSIBLE_FIRST_STAGE_MODULES := $(foreach module,$(ACCESSIBLE_FIRST_STAGE_MODULE_NAMES),$(wildcard $(KERNEL_MODULE_DIR)/$(module)))
BOARD_VENDOR_RAMDISK_KERNEL_MODULES := $(ACCESSIBLE_FIRST_STAGE_MODULES)
BOARD_VENDOR_RAMDISK_KERNEL_MODULES_LOAD := $(ACCESSIBLE_FIRST_STAGE_MODULES)

# Keep the complete module set available after /vendor is mounted. Limit the
# automatic second-stage list to the VM devices needed by the initial product.
BOARD_VENDOR_KERNEL_MODULES := $(KERNEL_MODULES)
ACCESSIBLE_RUNTIME_MODULE_NAMES := \
    virtio-gpu.ko \
    virtio-rng.ko \
    virtio_dma_buf.ko \
    virtio_input.ko \
    virtio_net.ko \
    virtio_snd.ko
BOARD_VENDOR_KERNEL_MODULES_LOAD := $(foreach module,$(ACCESSIBLE_RUNTIME_MODULE_NAMES),$(wildcard $(KERNEL_MODULE_DIR)/$(module)))

# Separate modern Android partitions. ext4 is the conservative first boot
# format; read-only EROFS can be evaluated after the VM bring-up is stable.
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USES_VENDORIMAGE := true
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USES_PRODUCTIMAGE := true
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USES_SYSTEM_EXTIMAGE := true
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
BOARD_USES_METADATA_PARTITION := true

# Dynamic partitions. Sizes follow the proven 7 GiB virtual-device envelope,
# while keeping system and vendor groups separate for future OTA evolution.
BOARD_SUPER_PARTITION_SIZE := 7516192768
BOARD_SUPER_PARTITION_GROUPS := accessible_system_dynamic_partitions accessible_vendor_dynamic_partitions
BOARD_ACCESSIBLE_SYSTEM_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext product
BOARD_ACCESSIBLE_SYSTEM_DYNAMIC_PARTITIONS_SIZE := 5771362304
BOARD_ACCESSIBLE_VENDOR_DYNAMIC_PARTITIONS_PARTITION_LIST := vendor
BOARD_ACCESSIBLE_VENDOR_DYNAMIC_PARTITIONS_SIZE := 1472200704
BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true
BOARD_SUPER_IMAGE_IN_UPDATE_PACKAGE := true

# A/B is designed in from the first installable disk format so updates can
# eventually roll back without destroying the user's data partition.
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    init_boot \
    vendor_boot \
    vbmeta \
    system \
    system_ext \
    product \
    vendor

# AVB is enabled for generated Android images. Development/userdebug builds use
# the normal AOSP signing flow; production keys will be supplied separately.
BOARD_AVB_ENABLE := true
BOARD_AVB_ALGORITHM := SHA256_RSA4096
BOARD_AVB_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem

TARGET_RECOVERY_FSTAB := $(LOCAL_ACCESSIBLE_DEVICE)/fstab.accessible_x86_64
