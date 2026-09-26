ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCam
VCam_FILES = Tweak.xm
VCam_FRAMEWORKS = AVFoundation CoreImage CoreMedia CoreVideo Foundation UIKit
VCam_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard 2>/dev/null || true"
