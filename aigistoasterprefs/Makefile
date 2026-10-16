TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = aigistoasterprefs

aigistoasterprefs_FILES = RootListController.m
aigistoasterprefs_FRAMEWORKS = UIKit
aigistoasterprefs_INSTALL_PATH = /Library/PreferenceBundles
aigistoasterprefs_CFLAGS = -fobjc-arc
aigistoasterprefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
