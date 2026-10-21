#
# Copyright (C) 2023 The Android Open Source Project
# Copyright (C) 2023 SebaUbuntu's TWRP device tree generator
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := device/samsung/a02

# 64-bit only userspace (no 32-bit secondary arch)
TARGET_SUPPORTS_32_BIT_APPS := false
TARGET_SUPPORTS_64_BIT_APPS := true

# --- Copy Files ---
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/recovery/root/system/etc/ueventd.rc:recovery/root/ueventd.rc \
    $(LOCAL_PATH)/recovery/root/init.recovery.mt6739.rc:recovery/root/init.recovery.mt6739.rc \
    $(LOCAL_PATH)/recovery/root/init.recovery.samsung.rc:recovery/root/init.recovery.samsung.rc \
    $(LOCAL_PATH)/recovery/root/init.recovery.usb.rc:recovery/root/init.recovery.usb.rc \
    $(LOCAL_PATH)/recovery/root/system/etc/recovery.fstab:recovery/root/system/etc/recovery.fstab \
    $(LOCAL_PATH)/recovery/root/system/etc/twrp.flags:recovery/root/system/etc/twrp.flags
