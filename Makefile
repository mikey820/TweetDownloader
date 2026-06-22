export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:16.5:14.0
ARCHS ?= arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := TweetDownloader
TweetDownloader_FILES := Tweak.x
TweetDownloader_CFLAGS := -fobjc-arc
TweetDownloader_FRAMEWORKS := UIKit Photos

include $(THEOS_MAKE_PATH)/tweak.mk
