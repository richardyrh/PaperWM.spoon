HAMMERSPOON_APP ?= /Applications/Hammerspoon.app
LUA_HEADERS := $(HAMMERSPOON_APP)/Contents/Frameworks/LuaSkin.framework/Headers
TARGET := paperwm_transform.so
SOURCE := paperwm_transform.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCE)
	xcrun clang -std=c11 -O2 -Wall -Wextra -Werror \
		-bundle -undefined dynamic_lookup \
		-I"$(LUA_HEADERS)" \
		-framework ApplicationServices \
		-o "$@" "$<"

clean:
	rm -f "$(TARGET)"
