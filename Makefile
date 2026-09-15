ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlobalFPSOverlay
GlobalFPSOverlay_FILES = Tweak.xm
GlobalFPSOverlay_CFLAGS = -fobjc-arc -O2
GlobalFPSOverlay_FRAMEWORKS = Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
