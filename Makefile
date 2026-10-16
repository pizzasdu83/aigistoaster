TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = aigistoaster

aigistoaster_FILES = Tweak.x
aigistoaster_CFLAGS = -fobjc-arc
aigistoaster_FRAMEWORKS = UIKit CoreImage QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += aigistoasterprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
