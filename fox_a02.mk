#
# OrangeFox product makefile - Samsung Galaxy A02 (SM-A022F, MT6739), 64-bit
#
# SPDX-License-Identifier: Apache-2.0
#

# Inherit some common stuff (whichever one the synced OrangeFox tree provides).
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)
$(call inherit-product-if-exists, vendor/twrp/config/common.mk)
$(call inherit-product-if-exists, vendor/omni/config/common.mk)

# Inherit from a02 device
$(call inherit-product, device/samsung/a02/device.mk)

PRODUCT_DEVICE := a02
PRODUCT_NAME := fox_a02
PRODUCT_BRAND := samsung
PRODUCT_MODEL := SM-A022F
PRODUCT_MANUFACTURER := samsung

PRODUCT_GMS_CLIENTID_BASE := android-samsung-ss
