MACHINE := $(shell uname -m)
BUILD := build
OSAX := $(BUILD)/PaperWM.osax
LOADER := $(OSAX)/Contents/MacOS/loader
PAYLOAD := $(OSAX)/Contents/Resources/payload.bundle/Contents/MacOS/payload
MONITOR := $(BUILD)/paperwm-injector
PROBE := $(BUILD)/paperwm-injector-probe
SIGNED := $(BUILD)/.signed

ifeq ($(MACHINE),arm64)
OSAX_ARCH := -arch arm64e
MONITOR_ARCH := -arch arm64
else
OSAX_ARCH := -arch x86_64
MONITOR_ARCH := -arch x86_64
endif

COMMON_FLAGS := -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=11.0

.PHONY: all clean check install uninstall probe

all: $(SIGNED)

$(LOADER): loader.m
	mkdir -p "$(dir $@)"
	cp PaperWM.osax.Info.plist "$(OSAX)/Contents/Info.plist"
	xcrun clang $(COMMON_FLAGS) -fno-objc-arc $(OSAX_ARCH) \
		-framework Cocoa -o "$@" loader.m

$(PAYLOAD): payload.m protocol.h
	mkdir -p "$(dir $@)"
	cp payload.Info.plist "$(OSAX)/Contents/Resources/payload.bundle/Contents/Info.plist"
	xcrun clang $(COMMON_FLAGS) -fno-objc-arc $(OSAX_ARCH) \
		-dynamiclib -fPIC -framework ApplicationServices -framework CoreVideo \
		-o "$@" payload.m

$(MONITOR): monitor.m client.c client.h protocol.h
	mkdir -p "$(dir $@)"
	xcrun clang $(COMMON_FLAGS) -fobjc-arc $(MONITOR_ARCH) \
		-framework AppKit -o "$@" monitor.m client.c

$(PROBE): probe.m client.c client.h protocol.h
	mkdir -p "$(dir $@)"
	xcrun clang $(COMMON_FLAGS) -fobjc-arc $(MONITOR_ARCH) \
		-framework AppKit -framework ApplicationServices \
		-o "$@" probe.m client.c

$(SIGNED): $(LOADER) $(PAYLOAD) $(MONITOR)
	codesign --force --deep --sign - "$(OSAX)"
	codesign --force --sign - "$(MONITOR)"
	touch "$@"

check: all $(PROBE)
	plutil -lint "$(OSAX)/Contents/Info.plist"
	plutil -lint "$(OSAX)/Contents/Resources/payload.bundle/Contents/Info.plist"
	codesign --verify --deep --strict "$(OSAX)"
	codesign --verify --strict "$(MONITOR)"

probe: $(PROBE)
	"$(PROBE)"

install: check
	./install.sh --no-build

uninstall:
	./install.sh --uninstall

clean:
	rm -rf "$(BUILD)"
