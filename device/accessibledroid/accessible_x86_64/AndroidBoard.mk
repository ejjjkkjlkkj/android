LOCAL_PATH := $(call my-dir)

ifeq ($(strip $(TARGET_NO_KERNEL)),false)
ifeq ($(wildcard $(TARGET_PREBUILT_KERNEL)),)
$(error AccessibleAndroid kernel is missing at $(TARGET_PREBUILT_KERNEL). Run scripts/sync-kernel.sh, scripts/build-kernel.sh and scripts/stage-kernel.sh before the Android build.)
endif

$(INSTALLED_KERNEL_TARGET): $(TARGET_PREBUILT_KERNEL) | $(ACP)
	$(copy-file-to-target)
endif
