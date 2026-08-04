HAMMERSPOON_APP ?= /Applications/Hammerspoon.app
LUA_HEADERS := $(HAMMERSPOON_APP)/Contents/Frameworks/LuaSkin.framework/Headers
TARGET := paperwm_transform.so
SOURCES := paperwm_transform.m injector/client.c
HEADERS := injector/client.h injector/protocol.h

.PHONY: all clean injector injector-check

all: $(TARGET)

$(TARGET): $(SOURCES) $(HEADERS)
	xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
		-bundle -undefined dynamic_lookup \
		-I"$(LUA_HEADERS)" \
		-framework ApplicationServices \
		-framework AppKit \
		-framework IOKit \
		-o "$@" $(SOURCES)

injector:
	$(MAKE) -C injector

injector-check:
	$(MAKE) -C injector check

clean:
	rm -f "$(TARGET)"
	$(MAKE) -C injector clean
