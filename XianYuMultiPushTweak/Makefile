THEOS_DEVICE_IP = 192.168.1.100
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XianYuMultiPushTweak

XianYuMultiPushTweak_FILES = Tweak.x
XianYuMultiPushTweak_CFLAGS = -fobjc-arc -Wno-error
XianYuMultiPushTweak_FRAMEWORKS = UIKit AVFoundation Security PushKit
XianYuMultiPushTweak_PRIVATE_FRAMEWORKS = 
XianYuMultiPushTweak_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Runner"