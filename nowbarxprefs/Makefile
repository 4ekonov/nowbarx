TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NowBarXPrefs

NowBarXPrefs_FILES = NBRootListController.m
NowBarXPrefs_FRAMEWORKS = UIKit
NowBarXPrefs_LDFLAGS = -undefined dynamic_lookup
NowBarXPrefs_INSTALL_PATH = /Library/PreferenceBundles
NowBarXPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
