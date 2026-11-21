TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NowBarX

NowBarX_FILES = Tweak.x NBSettings.m NBDataSource.m NBBarView.m
NowBarX_FRAMEWORKS = UIKit QuartzCore
NowBarX_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DNB_DEBUG=1

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += nowbarxprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
