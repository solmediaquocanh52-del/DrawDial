TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobilePhone

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DrawDial
DrawDial_FILES = Tweak.x
DrawDial_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
DrawDial_FRAMEWORKS = UIKit Vision Contacts CoreGraphics
DrawDial_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
