#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#import <AppKit/NSHapticFeedback.h>
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <lua.h>
#include <lauxlib.h>

#include "injector/client.h"

typedef int CGSConnectionID;
typedef int CGSWindowID;

typedef CGSConnectionID (*CGSMainConnectionIDFn)(void);
typedef CGSConnectionID (*CGSDefaultConnectionFn)(void);
typedef CGError (*CGSGetWindowOwnerFn)(CGSConnectionID,
                                       CGSWindowID,
                                       CGSConnectionID *);
typedef CGError (*CGSGetWindowBoundsFn)(CGSConnectionID,
                                        CGSWindowID,
                                        CGRect *);
typedef CGError (*CGSGetWindowTransformFn)(CGSConnectionID,
                                           CGSWindowID,
                                           CGAffineTransform *);
typedef CGError (*CGSSetWindowTransformFn)(CGSConnectionID,
                                           CGSWindowID,
                                           CGAffineTransform);
typedef CGError (*CGSSetWindowTransformsFn)(CGSConnectionID,
                                            const CGSWindowID *,
                                            const CGAffineTransform *,
                                            int);
typedef CGError (*CGSDisableUpdateFn)(CGSConnectionID);
typedef CGError (*CGSReenableUpdateFn)(CGSConnectionID);
typedef CGError (*CGSMoveWindowFn)(CGSConnectionID, CGSWindowID, const CGPoint *);

static void *skyLight = NULL;
static CGSMainConnectionIDFn mainConnectionID = NULL;
static CGSMainConnectionIDFn slsMainConnectionID = NULL;
static CGSDefaultConnectionFn defaultConnection = NULL;
static CGSGetWindowOwnerFn getWindowOwner = NULL;
static CGSGetWindowBoundsFn getWindowBounds = NULL;
static CGSGetWindowTransformFn getWindowTransform = NULL;
static CGSSetWindowTransformFn setWindowTransform = NULL;
static CGSSetWindowTransformsFn setWindowTransforms = NULL;
static CGSDisableUpdateFn disableUpdate = NULL;
static CGSReenableUpdateFn reenableUpdate = NULL;
static CGSMoveWindowFn moveWindow = NULL;
static const char *loadError = NULL;

typedef enum {
    NATIVE_ROUTE_UNKNOWN = 0,
    NATIVE_ROUTE_SKYLIGHT,
    NATIVE_ROUTE_DOCK,
    NATIVE_ROUTE_UNAVAILABLE,
} NativeRoute;

static NativeRoute transformRoute = NATIVE_ROUTE_UNKNOWN;
static NativeRoute moveRoute = NATIVE_ROUTE_UNKNOWN;
static bool dockCapabilityChecked = false;
static uint32_t dockCapabilities = 0;
static char dockCapabilityError[256] = {0};

#define HIDPP_LONG_REPORT 0x11
#define HIDPP_SHORT_REPORT 0x10
#define HIDPP_MAX_DEVICES 8
#define HIDPP_REPORT_SIZE 64

typedef struct {
    IOHIDDeviceRef device;
    uint8_t buffer[HIDPP_REPORT_SIZE];
} HIDPPDevice;

static IOHIDManagerRef hidppManager = NULL;
static HIDPPDevice hidppDevices[HIDPP_MAX_DEVICES];
static uint8_t hidppFeatureIndex = 0x09;
static uint16_t hidppGestureCID = 0x00c3;
static HIDPPDevice *hidppGestureSource = NULL;
static uint8_t hidppGestureDeviceIndex = 0;
static bool hidppGestureDown = false;
static bool hidppGestureBegan = false;
static bool hidppGestureEnded = false;
static bool hidppDiscardNextRaw = false;
static int32_t hidppAccumulatedX = 0;
static int32_t hidppAccumulatedY = 0;

static int pushCGError(lua_State *L, CGError error);
static bool transformsEqual(CGAffineTransform a, CGAffineTransform b);

static const char *nativeRouteName(NativeRoute route) {
    switch (route) {
    case NATIVE_ROUTE_SKYLIGHT: return "skylight";
    case NATIVE_ROUTE_DOCK: return "dock";
    case NATIVE_ROUTE_UNAVAILABLE: return "unavailable";
    case NATIVE_ROUTE_UNKNOWN: return "unknown";
    }
    return "unknown";
}

static void invalidateDockCapabilities(const char *error) {
    dockCapabilityChecked = false;
    dockCapabilities = 0;
    if (error && *error) {
        snprintf(dockCapabilityError, sizeof(dockCapabilityError), "%s", error);
    } else {
        dockCapabilityError[0] = '\0';
    }
}

static bool refreshDockCapabilities(void) {
    paperwm_injector_response_t response = {0};
    char error[sizeof(dockCapabilityError)] = {0};
    bool available = paperwm_injector_handshake(
        getuid(), &response, error, sizeof(error));
    dockCapabilityChecked = true;
    dockCapabilities = available ? response.capabilities : 0;
    if (available) {
        dockCapabilityError[0] = '\0';
    } else {
        snprintf(dockCapabilityError, sizeof(dockCapabilityError), "%s", error);
    }
    return available;
}

static bool dockHasCapability(uint32_t capability, bool refresh) {
    if (refresh || !dockCapabilityChecked) refreshDockCapabilities();
    return (dockCapabilities & capability) == capability;
}

static int pushNativeRouteError(lua_State *L,
                                const char *operation,
                                const char *error) {
    lua_pushnil(L);
    lua_pushfstring(L,
                    "%s backend failed for %s: %s",
                    nativeRouteName(strcmp(operation, "move") == 0 ?
                                        moveRoute : transformRoute),
                    operation,
                    (error && *error) ? error : "unknown error");
    return 2;
}

static void hidppInputReport(void *context,
                             IOReturn result,
                             void *sender,
                             IOHIDReportType type,
                             uint32_t reportID,
                             uint8_t *report,
                             CFIndex length) {
    (void)sender;
    (void)type;
    (void)reportID;
    if (result != kIOReturnSuccess || length < 6) return;
    if (report[0] != HIDPP_LONG_REPORT && report[0] != HIDPP_SHORT_REPORT) return;
    if (report[2] != hidppFeatureIndex) return;

    if (report[3] == 0x00) {
        uint16_t cid = ((uint16_t)report[4] << 8) | report[5];
        if (cid == hidppGestureCID && !hidppGestureDown) {
            hidppGestureSource = context;
            hidppGestureDeviceIndex = report[1];
            hidppGestureDown = true;
            hidppGestureBegan = true;
            hidppGestureEnded = false;
            hidppDiscardNextRaw = true;
            hidppAccumulatedX = 0;
            hidppAccumulatedY = 0;
        } else if (cid == 0 && hidppGestureDown &&
                   context == hidppGestureSource &&
                   report[1] == hidppGestureDeviceIndex) {
            hidppGestureDown = false;
            hidppGestureEnded = true;
            hidppDiscardNextRaw = false;
        }
        return;
    }

    if ((report[3] & 0xf0) == 0x10 && hidppGestureDown && length >= 8 &&
        context == hidppGestureSource &&
        report[1] == hidppGestureDeviceIndex) {
        int16_t dx = (int16_t)(((uint16_t)report[4] << 8) | report[5]);
        int16_t dy = (int16_t)(((uint16_t)report[6] << 8) | report[7]);
        if (hidppDiscardNextRaw) {
            hidppDiscardNextRaw = false;
        } else {
            hidppAccumulatedX += dx;
            hidppAccumulatedY += dy;
        }
    }
}

static void hidppDeviceMatched(void *context,
                               IOReturn result,
                               void *sender,
                               IOHIDDeviceRef device) {
    (void)context;
    (void)sender;
    if (result != kIOReturnSuccess) return;

    for (int i = 0; i < HIDPP_MAX_DEVICES; i++) {
        if (hidppDevices[i].device == device) return;
    }
    for (int i = 0; i < HIDPP_MAX_DEVICES; i++) {
        if (hidppDevices[i].device) continue;
        if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess) return;

        hidppDevices[i].device = device;
        IOHIDDeviceRegisterInputReportCallback(
            device, hidppDevices[i].buffer, sizeof(hidppDevices[i].buffer),
            hidppInputReport, &hidppDevices[i]);
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        return;
    }
}

static void hidppDeviceRemoved(void *context,
                               IOReturn result,
                               void *sender,
                               IOHIDDeviceRef device) {
    (void)context;
    (void)result;
    (void)sender;
    for (int i = 0; i < HIDPP_MAX_DEVICES; i++) {
        if (hidppDevices[i].device != device) continue;
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
        if (&hidppDevices[i] == hidppGestureSource) {
            if (hidppGestureDown) hidppGestureEnded = true;
            hidppGestureDown = false;
            hidppGestureSource = NULL;
            hidppGestureDeviceIndex = 0;
        }
        hidppDevices[i].device = NULL;
        return;
    }
}

static int hidppMonitorStart(lua_State *L) {
    hidppFeatureIndex = (uint8_t)luaL_optinteger(L, 1, 0x09);
    hidppGestureCID = (uint16_t)luaL_optinteger(L, 2, 0x00c3);
    hidppGestureDown = false;
    hidppGestureSource = NULL;
    hidppGestureDeviceIndex = 0;
    hidppGestureBegan = false;
    hidppGestureEnded = false;
    hidppDiscardNextRaw = false;
    hidppAccumulatedX = 0;
    hidppAccumulatedY = 0;
    if (hidppManager) {
        lua_pushboolean(L, 1);
        return 1;
    }

    hidppManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!hidppManager) {
        lua_pushnil(L);
        lua_pushstring(L, "could not create IOHIDManager");
        return 2;
    }

    @autoreleasepool {
        NSArray *matching = @[
            @{
                @kIOHIDVendorIDKey: @0x046d,
                @kIOHIDPrimaryUsagePageKey: @0xff00,
            },
            @{
                @kIOHIDVendorIDKey: @0x046d,
                @kIOHIDPrimaryUsagePageKey: @0x01,
                @kIOHIDPrimaryUsageKey: @0x02,
            },
        ];
        IOHIDManagerSetDeviceMatchingMultiple(
            hidppManager, (__bridge CFArrayRef)matching);
    }
    IOHIDManagerRegisterDeviceMatchingCallback(
        hidppManager, hidppDeviceMatched, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(
        hidppManager, hidppDeviceRemoved, NULL);
    IOHIDManagerScheduleWithRunLoop(
        hidppManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn opened = IOHIDManagerOpen(hidppManager, kIOHIDOptionsTypeNone);
    if (opened != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(
            hidppManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(hidppManager);
        hidppManager = NULL;
        lua_pushnil(L);
        lua_pushfstring(L, "could not open IOHIDManager: 0x%x", opened);
        return 2;
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int hidppMonitorPoll(lua_State *L) {
    if (!hidppManager) {
        lua_pushnil(L);
        lua_pushstring(L, "HID++ gesture monitor is not running");
        return 2;
    }

    lua_createtable(L, 0, 5);
    lua_pushboolean(L, hidppGestureDown);
    lua_setfield(L, -2, "active");
    lua_pushboolean(L, hidppGestureBegan);
    lua_setfield(L, -2, "began");
    lua_pushboolean(L, hidppGestureEnded);
    lua_setfield(L, -2, "ended");
    lua_pushinteger(L, hidppAccumulatedX);
    lua_setfield(L, -2, "dx");
    lua_pushinteger(L, hidppAccumulatedY);
    lua_setfield(L, -2, "dy");

    hidppGestureBegan = false;
    hidppGestureEnded = false;
    hidppAccumulatedX = 0;
    hidppAccumulatedY = 0;
    return 1;
}

static int hidppMonitorStop(lua_State *L) {
    (void)L;
    if (hidppManager) {
        for (int i = 0; i < HIDPP_MAX_DEVICES; i++) {
            IOHIDDeviceRef device = hidppDevices[i].device;
            if (!device) continue;
            IOHIDDeviceUnscheduleFromRunLoop(
                device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
            IOHIDDeviceClose(device, kIOHIDOptionsTypeNone);
            hidppDevices[i].device = NULL;
        }
        IOHIDManagerUnscheduleFromRunLoop(
            hidppManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(hidppManager, kIOHIDOptionsTypeNone);
        CFRelease(hidppManager);
        hidppManager = NULL;
    }
    hidppGestureDown = false;
    hidppGestureSource = NULL;
    hidppGestureDeviceIndex = 0;
    hidppGestureBegan = false;
    hidppGestureEnded = false;
    hidppDiscardNextRaw = false;
    hidppAccumulatedX = 0;
    hidppAccumulatedY = 0;
    lua_pushboolean(L, 1);
    return 1;
}

static bool loadSkyLight(void) {
    if (skyLight) return true;
    if (loadError) return false;

    skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                     RTLD_LAZY | RTLD_LOCAL);
    if (!skyLight) {
        loadError = dlerror();
        return false;
    }

    mainConnectionID = (CGSMainConnectionIDFn)dlsym(skyLight, "CGSMainConnectionID");
    slsMainConnectionID =
        (CGSMainConnectionIDFn)dlsym(skyLight, "SLSMainConnectionID");
    defaultConnection =
        (CGSDefaultConnectionFn)dlsym(skyLight, "_CGSDefaultConnection");
    getWindowOwner =
        (CGSGetWindowOwnerFn)dlsym(skyLight, "CGSGetWindowOwner");
    if (!getWindowOwner) {
        getWindowOwner =
            (CGSGetWindowOwnerFn)dlsym(skyLight, "SLSGetWindowOwner");
    }
    getWindowBounds =
        (CGSGetWindowBoundsFn)dlsym(skyLight, "CGSGetWindowBounds");
    if (!getWindowBounds) {
        getWindowBounds =
            (CGSGetWindowBoundsFn)dlsym(skyLight, "SLSGetWindowBounds");
    }
    getWindowTransform =
        (CGSGetWindowTransformFn)dlsym(skyLight, "CGSGetWindowTransform");
    if (!getWindowTransform) {
        getWindowTransform =
            (CGSGetWindowTransformFn)dlsym(skyLight, "SLSGetWindowTransform");
    }
    setWindowTransform =
        (CGSSetWindowTransformFn)dlsym(skyLight, "CGSSetWindowTransform");
    if (!setWindowTransform) {
        setWindowTransform =
            (CGSSetWindowTransformFn)dlsym(skyLight, "SLSSetWindowTransform");
    }
    setWindowTransforms =
        (CGSSetWindowTransformsFn)dlsym(skyLight, "CGSSetWindowTransforms");
    disableUpdate = (CGSDisableUpdateFn)dlsym(skyLight, "CGSDisableUpdate");
    reenableUpdate = (CGSReenableUpdateFn)dlsym(skyLight, "CGSReenableUpdate");
    moveWindow = (CGSMoveWindowFn)dlsym(skyLight, "CGSMoveWindow");

    if (!mainConnectionID || !getWindowBounds || !setWindowTransform ||
        !disableUpdate || !reenableUpdate) {
        loadError = "required SkyLight symbols are unavailable";
        dlclose(skyLight);
        skyLight = NULL;
        return false;
    }
    return true;
}

static int windowBounds(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);

    lua_Integer count = luaL_len(L, 1);
    CGSConnectionID connection = mainConnectionID();
    lua_createtable(L, (int)count, 0);
    lua_Integer outputIndex = 1;
    for (lua_Integer i = 1; i <= count; i++) {
        lua_geti(L, 1, i);
        CGSWindowID windowID = (CGSWindowID)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        CGRect bounds = CGRectZero;
        if (getWindowBounds(connection, windowID, &bounds) != kCGErrorSuccess) {
            continue;
        }

        lua_createtable(L, 0, 5);
        lua_pushinteger(L, windowID);
        lua_setfield(L, -2, "id");
        lua_pushnumber(L, bounds.origin.x);
        lua_setfield(L, -2, "x");
        lua_pushnumber(L, bounds.origin.y);
        lua_setfield(L, -2, "y");
        lua_pushnumber(L, bounds.size.width);
        lua_setfield(L, -2, "w");
        lua_pushnumber(L, bounds.size.height);
        lua_setfield(L, -2, "h");
        lua_seti(L, -2, outputIndex++);
    }
    return 1;
}

static CGError moveOneWindow(CGSConnectionID connection,
                             CGSWindowID windowID,
                             CGPoint point,
                             CGSConnectionID *ownerOut) {
    CGSConnectionID windowConnection = connection;
    CGSConnectionID ownerConnection = 0;
    if (getWindowOwner &&
        getWindowOwner(connection, windowID, &ownerConnection) ==
            kCGErrorSuccess && ownerConnection) {
        windowConnection = ownerConnection;
    }
    if (ownerOut) *ownerOut = ownerConnection;

    CGError error = moveWindow(windowConnection, windowID, &point);
    if (error != kCGErrorSuccess && windowConnection != connection) {
        error = moveWindow(connection, windowID, &point);
    }
    return error;
}

static paperwm_injector_move_t *readMoveTable(lua_State *L,
                                              int tableIndex,
                                              uint32_t *countOut) {
    tableIndex = lua_absindex(L, tableIndex);
    lua_Integer luaCount = luaL_len(L, tableIndex);
    if (luaCount < 0 || (uint64_t)luaCount > UINT32_MAX) {
        luaL_error(L, "native move batch is too large");
    }
    uint32_t count = (uint32_t)luaCount;
    paperwm_injector_move_t *moves =
        count > 0 ? calloc(count, sizeof(*moves)) : NULL;
    if (count > 0 && !moves) {
        luaL_error(L, "could not allocate native move batch");
    }

    for (uint32_t index = 0; index < count; ++index) {
        lua_geti(L, tableIndex, (lua_Integer)index + 1);
        luaL_checktype(L, -1, LUA_TTABLE);

        lua_getfield(L, -1, "id");
        moves[index].window_id = (uint32_t)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "x");
        moves[index].x = luaL_checknumber(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "y");
        moves[index].y = luaL_checknumber(L, -1);
        lua_pop(L, 1);
        lua_pop(L, 1);
    }

    *countOut = count;
    return moves;
}

static int windowMove(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);

    uint32_t count = 0;
    paperwm_injector_move_t *moves = readMoveTable(L, 1, &count);
    if (count == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }

    char dockError[256] = {0};
    if (moveRoute == NATIVE_ROUTE_DOCK) {
        bool moved = paperwm_injector_move(
            getuid(), moves, count, NULL,
            dockError, sizeof(dockError));
        if (moved) {
            free(moves);
            lua_pushboolean(L, 1);
            return 1;
        }
        invalidateDockCapabilities(dockError);
    }

    if (moveRoute == NATIVE_ROUTE_UNAVAILABLE &&
        dockHasCapability(PAPERWM_INJECTOR_CAP_MOVE, true) &&
        paperwm_injector_move(getuid(), moves, count, NULL,
                              dockError, sizeof(dockError))) {
        moveRoute = NATIVE_ROUTE_DOCK;
        free(moves);
        lua_pushboolean(L, 1);
        return 1;
    }

    if (!moveWindow) {
        free(moves);
        moveRoute = NATIVE_ROUTE_UNAVAILABLE;
        return pushNativeRouteError(
            L, "move", dockError[0] ? dockError : "CGSMoveWindow is unavailable");
    }

    CGSConnectionID connection = mainConnectionID();
    CGError directError = kCGErrorSuccess;
    CGSConnectionID failedOwner = 0;
    uint32_t failedWindow = 0;
    for (uint32_t i = 0; i < count; i++) {
        CGPoint point = CGPointMake(moves[i].x, moves[i].y);
        CGSConnectionID ownerConnection = 0;
        directError = moveOneWindow(
            connection, moves[i].window_id, point, &ownerConnection);
        if (directError != kCGErrorSuccess) {
            failedOwner = ownerConnection;
            failedWindow = moves[i].window_id;
            break;
        }
    }

    if (directError == kCGErrorSuccess) {
        moveRoute = NATIVE_ROUTE_SKYLIGHT;
        free(moves);
        lua_pushboolean(L, 1);
        return 1;
    }

    if (dockHasCapability(PAPERWM_INJECTOR_CAP_MOVE, true) &&
        paperwm_injector_move(getuid(), moves, count, NULL,
                              dockError, sizeof(dockError))) {
        moveRoute = NATIVE_ROUTE_DOCK;
        free(moves);
        lua_pushboolean(L, 1);
        return 1;
    }

    moveRoute = NATIVE_ROUTE_UNAVAILABLE;
    free(moves);
    lua_pushnil(L);
    if (dockError[0]) {
        lua_pushfstring(
            L,
            "native move unavailable: SkyLight CGError %d for window %d "
            "(owner %d, main %d); Dock: %s",
            directError, failedWindow, failedOwner, connection, dockError);
    } else {
        lua_pushfstring(
            L,
            "native move unavailable: SkyLight CGError %d for window %d "
            "(owner %d, main %d); Dock payload unavailable",
            directError, failedWindow, failedOwner, connection);
    }
    return 2;
}

typedef bool (*PaperWMInteractiveRequestFn)(
    uid_t,
    const paperwm_injector_move_t *,
    uint32_t,
    paperwm_injector_response_t *,
    char *,
    size_t);

static int windowInteractiveRequest(lua_State *L,
                                    PaperWMInteractiveRequestFn request,
                                    const char *operation,
                                    bool requireCapability) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (requireCapability &&
        !dockHasCapability(PAPERWM_INJECTOR_CAP_INTERACTIVE, false)) {
        lua_pushnil(L);
        lua_pushstring(L, "Dock display-link interaction is unavailable");
        return 2;
    }

    uint32_t count = 0;
    paperwm_injector_move_t *moves = readMoveTable(L, 1, &count);
    char error[256] = {0};
    bool succeeded = request(
        getuid(), moves, count, NULL, error, sizeof(error));
    free(moves);
    if (!succeeded) {
        invalidateDockCapabilities(error);
        lua_pushnil(L);
        lua_pushfstring(L,
                        "Dock display-link interaction %s failed: %s",
                        operation,
                        error);
        return 2;
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int windowInteractiveBegin(lua_State *L) {
    return windowInteractiveRequest(
        L, paperwm_injector_interactive_begin, "begin", true);
}

static int windowInteractiveUpdate(lua_State *L) {
    return windowInteractiveRequest(
        L, paperwm_injector_interactive_update, "update", true);
}

static int windowInteractiveEnd(lua_State *L) {
    return windowInteractiveRequest(
        L, paperwm_injector_interactive_end, "end", false);
}

static int windowAnimate(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);

    if (!dockHasCapability(PAPERWM_INJECTOR_CAP_ANIMATE, false)) {
        lua_pushnil(L);
        lua_pushstring(L, "Dock display-link animation is unavailable");
        return 2;
    }

    lua_Integer count = luaL_len(L, 1);
    paperwm_injector_animation_t *animations =
        calloc((size_t)count, sizeof(*animations));
    if (count > 0 && !animations) {
        return luaL_error(L, "could not allocate native animation batch");
    }

    for (lua_Integer i = 1; i <= count; ++i) {
        paperwm_injector_animation_t *animation = &animations[i - 1];
        lua_geti(L, 1, i);
        luaL_checktype(L, -1, LUA_TTABLE);

        lua_getfield(L, -1, "id");
        animation->window_id = (uint32_t)luaL_checkinteger(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, -1, "direct");
        if (lua_toboolean(L, -1)) {
            animation->flags |= PAPERWM_INJECTOR_ANIMATION_MOVE;
        }
        lua_pop(L, 1);

        lua_getfield(L, -1, "auto_commit");
        if (lua_toboolean(L, -1)) {
            animation->flags |= PAPERWM_INJECTOR_ANIMATION_AUTO_COMMIT;
        }
        lua_pop(L, 1);

#define READ_ANIMATION_NUMBER(field) \
        lua_getfield(L, -1, #field); \
        animation->field = luaL_checknumber(L, -1); \
        lua_pop(L, 1)
        READ_ANIMATION_NUMBER(start_x);
        READ_ANIMATION_NUMBER(start_y);
        READ_ANIMATION_NUMBER(end_x);
        READ_ANIMATION_NUMBER(end_y);
        READ_ANIMATION_NUMBER(start_sx);
        READ_ANIMATION_NUMBER(start_sy);
        READ_ANIMATION_NUMBER(end_sx);
        READ_ANIMATION_NUMBER(end_sy);
        READ_ANIMATION_NUMBER(duration);
        READ_ANIMATION_NUMBER(curve_x1);
        READ_ANIMATION_NUMBER(curve_y1);
        READ_ANIMATION_NUMBER(curve_x2);
        READ_ANIMATION_NUMBER(curve_y2);
#undef READ_ANIMATION_NUMBER
        lua_pop(L, 1);
    }

    char error[256] = {0};
    bool started = paperwm_injector_animate(
        getuid(), animations, (uint32_t)count, NULL, error, sizeof(error));
    free(animations);
    if (!started) {
        invalidateDockCapabilities(error);
        lua_pushnil(L);
        lua_pushfstring(L, "Dock display-link animation failed: %s", error);
        return 2;
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int pushCGError(lua_State *L, CGError error) {
    if (error == kCGErrorSuccess) {
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushnil(L);
    lua_pushfstring(L, "SkyLight returned CGError %d", error);
    return 2;
}

static int transformAvailable(lua_State *L) {
    if (loadSkyLight()) {
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushboolean(L, 0);
    lua_pushstring(L, loadError ? loadError : "could not load SkyLight");
    return 2;
}

static void setIntegerField(lua_State *L, const char *field, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, field);
}

static void setBooleanField(lua_State *L, const char *field, bool value) {
    lua_pushboolean(L, value);
    lua_setfield(L, -2, field);
}

static void setStringField(lua_State *L, const char *field, const char *value) {
    lua_pushstring(L, value);
    lua_setfield(L, -2, field);
}

static void setErrorField(lua_State *L, const char *field, CGError error) {
    setIntegerField(L, field, (lua_Integer)error);
}

static void setRectField(lua_State *L, const char *field, CGRect rect) {
    lua_createtable(L, 0, 4);
    lua_pushnumber(L, rect.origin.x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, rect.origin.y);
    lua_setfield(L, -2, "y");
    lua_pushnumber(L, rect.size.width);
    lua_setfield(L, -2, "w");
    lua_pushnumber(L, rect.size.height);
    lua_setfield(L, -2, "h");
    lua_setfield(L, -2, field);
}

static void setTransformField(lua_State *L,
                              const char *field,
                              CGAffineTransform transform) {
    lua_createtable(L, 0, 6);
    lua_pushnumber(L, transform.a);
    lua_setfield(L, -2, "a");
    lua_pushnumber(L, transform.b);
    lua_setfield(L, -2, "b");
    lua_pushnumber(L, transform.c);
    lua_setfield(L, -2, "c");
    lua_pushnumber(L, transform.d);
    lua_setfield(L, -2, "d");
    lua_pushnumber(L, transform.tx);
    lua_setfield(L, -2, "tx");
    lua_pushnumber(L, transform.ty);
    lua_setfield(L, -2, "ty");
    lua_setfield(L, -2, field);
}

static CGSWindowID probeWindowID(lua_State *L, lua_Integer index) {
    lua_geti(L, 1, index);
    CGSWindowID windowID;
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "id");
        windowID = (CGSWindowID)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
    } else {
        windowID = (CGSWindowID)luaL_checkinteger(L, -1);
    }
    lua_pop(L, 1);
    return windowID;
}

// Determine whether this connection can actually write a foreign window.
// Symbol availability is insufficient on newer WindowServer builds: read-only
// operations can work while transform and position writes are denied. Reapply
// the current values so the probe has no visible effect.
static int backendProbe(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);

    transformRoute = NATIVE_ROUTE_UNKNOWN;
    moveRoute = NATIVE_ROUTE_UNKNOWN;

    CGSConnectionID connection = mainConnectionID();
    CGSWindowID windowID = 0;
    CGSConnectionID ownerConnection = 0;
    CGError ownerError = kCGErrorSuccess;
    lua_Integer count = luaL_len(L, 1);

    for (lua_Integer i = 1; i <= count; i++) {
        CGSWindowID candidate = probeWindowID(L, i);
        CGSConnectionID owner = 0;
        CGError error = getWindowOwner ?
            getWindowOwner(connection, candidate, &owner) : kCGErrorFailure;
        if (error == kCGErrorSuccess && owner && owner != connection) {
            windowID = candidate;
            ownerConnection = owner;
            ownerError = error;
            break;
        }
        ownerError = error;
    }

    lua_createtable(L, 0, 10);
    setIntegerField(L, "main_connection", connection);
    if (!windowID) {
        setBooleanField(L, "checked", false);
        setErrorField(L, "owner_lookup_error", ownerError);
        lua_pushstring(L, "no foreign managed window is available to probe");
        lua_setfield(L, -2, "reason");
        return 1;
    }

    setBooleanField(L, "checked", true);
    setIntegerField(L, "window_id", windowID);
    setIntegerField(L, "owner_connection", ownerConnection);

    CGAffineTransform transform = CGAffineTransformIdentity;
    CGError getTransformError = getWindowTransform ?
        getWindowTransform(connection, windowID, &transform) : kCGErrorFailure;
    CGError batchTransformError = getTransformError;
    if (batchTransformError == kCGErrorSuccess) {
        batchTransformError = setWindowTransforms ?
            setWindowTransforms(connection, &windowID, &transform, 1) :
            kCGErrorFailure;
    }
    setErrorField(L, "batch_transform_error", batchTransformError);

    CGError singularTransformError = kCGErrorFailure;
    const char *transformMode = NULL;
    if (batchTransformError == kCGErrorSuccess) {
        transformMode = "batch";
        singularTransformError = kCGErrorSuccess;
    } else if (getTransformError == kCGErrorSuccess && setWindowTransform) {
        CGAffineTransform probe = transform;
        probe.tx += 0.25;
        singularTransformError =
            setWindowTransform(connection, windowID, probe);
        if (singularTransformError == kCGErrorSuccess) {
            CGAffineTransform readback = CGAffineTransformIdentity;
            CGError readbackError =
                getWindowTransform(connection, windowID, &readback);
            bool applied = readbackError == kCGErrorSuccess &&
                transformsEqual(readback, probe);

            // Always restore after a successful setter call, even if readback
            // did not match the request.
            CGError restoreError =
                setWindowTransform(connection, windowID, transform);
            readback = CGAffineTransformIdentity;
            CGError restoreReadbackError = restoreError == kCGErrorSuccess ?
                getWindowTransform(connection, windowID, &readback) :
                restoreError;
            bool restored = restoreReadbackError == kCGErrorSuccess &&
                transformsEqual(readback, transform);
            singularTransformError = applied && restored ?
                kCGErrorSuccess : kCGErrorFailure;
        }
        if (singularTransformError == kCGErrorSuccess) {
            transformMode = "singular";
        }
    }
    setErrorField(L, "singular_transform_error", singularTransformError);

    CGRect bounds = CGRectZero;
    CGError moveError = getWindowBounds ?
        getWindowBounds(connection, windowID, &bounds) : kCGErrorFailure;
    CGSConnectionID moveOwner = 0;
    if (moveError == kCGErrorSuccess) {
        moveError = moveWindow ?
            moveOneWindow(connection, windowID, bounds.origin, &moveOwner) :
            kCGErrorFailure;
    }
    if (moveOwner) setIntegerField(L, "move_owner_connection", moveOwner);

    bool directTransform = transformMode != NULL;
    bool directMove = moveError == kCGErrorSuccess;
    // The Dock may provide display-linked animation/interaction even when
    // direct SkyLight writes still work on this OS version.
    bool dockReady = refreshDockCapabilities();

    if (directTransform) {
        transformRoute = NATIVE_ROUTE_SKYLIGHT;
    } else if (dockReady &&
               (dockCapabilities & PAPERWM_INJECTOR_CAP_TRANSFORM)) {
        transformRoute = NATIVE_ROUTE_DOCK;
        transformMode = "dock";
    } else {
        transformRoute = NATIVE_ROUTE_UNAVAILABLE;
    }

    if (directMove) {
        moveRoute = NATIVE_ROUTE_SKYLIGHT;
    } else if (dockReady && (dockCapabilities & PAPERWM_INJECTOR_CAP_MOVE)) {
        moveRoute = NATIVE_ROUTE_DOCK;
    } else {
        moveRoute = NATIVE_ROUTE_UNAVAILABLE;
    }

    bool transformAvailable = transformRoute != NATIVE_ROUTE_UNAVAILABLE;
    bool moveAvailable = moveRoute != NATIVE_ROUTE_UNAVAILABLE;
    bool animationAvailable = transformRoute == NATIVE_ROUTE_DOCK &&
        dockReady && (dockCapabilities & PAPERWM_INJECTOR_CAP_ANIMATE);
    bool interactiveAvailable = dockReady &&
        (dockCapabilities & PAPERWM_INJECTOR_CAP_INTERACTIVE);
    setBooleanField(L, "transform", transformAvailable);
    setBooleanField(L, "move", moveAvailable);
    setBooleanField(L, "animation", animationAvailable);
    setBooleanField(L, "interactive", interactiveAvailable);
    setErrorField(L, "transform_error", transformAvailable ?
        kCGErrorSuccess : singularTransformError);
    setErrorField(L, "move_error", moveAvailable ?
        kCGErrorSuccess : moveError);
    setStringField(L, "transform_backend", nativeRouteName(transformRoute));
    setStringField(L, "move_backend", nativeRouteName(moveRoute));
    if (transformMode) setStringField(L, "transform_mode", transformMode);
    if (dockReady) {
        setIntegerField(L, "dock_capabilities", dockCapabilities);
    } else if (dockCapabilityError[0]) {
        lua_pushstring(L, dockCapabilityError);
        lua_setfield(L, -2, "dock_error");
    }
    return 1;
}

static void probeConnection(lua_State *L,
                            const char *prefix,
                            CGSConnectionID connection,
                            CGSWindowID windowID,
                            CGAffineTransform transform) {
    char field[80];
    if (!connection) return;

    if (getWindowBounds) {
        CGRect bounds = CGRectZero;
        CGError error = getWindowBounds(connection, windowID, &bounds);
        snprintf(field, sizeof(field), "%s_bounds_error", prefix);
        setErrorField(L, field, error);
        if (error == kCGErrorSuccess) {
            snprintf(field, sizeof(field), "%s_bounds", prefix);
            setRectField(L, field, bounds);
        }
    }

    if (getWindowTransform) {
        CGAffineTransform current = CGAffineTransformIdentity;
        CGError error = getWindowTransform(connection, windowID, &current);
        snprintf(field, sizeof(field), "%s_get_transform_error", prefix);
        setErrorField(L, field, error);
        if (error == kCGErrorSuccess) {
            snprintf(field, sizeof(field), "%s_transform", prefix);
            setTransformField(L, field, current);
            transform = current;
        }
    }

    if (setWindowTransform) {
        CGError error = setWindowTransform(connection, windowID, transform);
        snprintf(field, sizeof(field), "%s_singular_set_error", prefix);
        setErrorField(L, field, error);
    }

    if (setWindowTransforms) {
        CGError error =
            setWindowTransforms(connection, &windowID, &transform, 1);
        snprintf(field, sizeof(field), "%s_batch_single_error", prefix);
        setErrorField(L, field, error);
    }
}

static int transformProbe(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);

    lua_Integer count = luaL_len(L, 1);
    CGSWindowID *windowIDs = calloc((size_t)count, sizeof(*windowIDs));
    CGAffineTransform *transforms = calloc((size_t)count, sizeof(*transforms));
    if ((count > 0) && (!windowIDs || !transforms)) {
        free(windowIDs);
        free(transforms);
        return luaL_error(L, "could not allocate probe batch");
    }
    for (lua_Integer i = 0; i < count; i++) {
        windowIDs[i] = probeWindowID(L, i + 1);
        transforms[i] = CGAffineTransformIdentity;
    }

    CGSConnectionID cgsMain = mainConnectionID();
    CGSConnectionID slsMain =
        slsMainConnectionID ? slsMainConnectionID() : 0;
    CGSConnectionID cgsDefault =
        defaultConnection ? defaultConnection() : 0;

    lua_createtable(L, 0, 8);
    setIntegerField(L, "cgs_main_connection", cgsMain);
    setIntegerField(L, "sls_main_connection", slsMain);
    setIntegerField(L, "cgs_default_connection", cgsDefault);
    setBooleanField(L, "has_get_owner", getWindowOwner != NULL);
    setBooleanField(L, "has_get_bounds", getWindowBounds != NULL);
    setBooleanField(L, "has_get_transform", getWindowTransform != NULL);
    setBooleanField(L, "has_singular_set", setWindowTransform != NULL);
    setBooleanField(L, "has_batch_set", setWindowTransforms != NULL);

    if (count > 0 && setWindowTransforms) {
        setErrorField(L, "cgs_main_batch_error",
            setWindowTransforms(cgsMain, windowIDs, transforms, (int)count));
        if (slsMain) {
            setErrorField(L, "sls_main_batch_error",
                setWindowTransforms(slsMain, windowIDs, transforms, (int)count));
        }
        if (cgsDefault) {
            setErrorField(L, "cgs_default_batch_error",
                setWindowTransforms(cgsDefault, windowIDs, transforms, (int)count));
        }
    }

    lua_createtable(L, (int)count, 0);
    for (lua_Integer i = 0; i < count; i++) {
        lua_createtable(L, 0, 24);
        setIntegerField(L, "id", windowIDs[i]);

        CGSConnectionID owner = 0;
        if (getWindowOwner) {
            CGError error = getWindowOwner(cgsMain, windowIDs[i], &owner);
            setErrorField(L, "owner_lookup_error", error);
            if (error == kCGErrorSuccess) {
                setIntegerField(L, "owner_connection", owner);
            }
        }

        probeConnection(L, "cgs_main", cgsMain, windowIDs[i], transforms[i]);
        if (slsMain && slsMain != cgsMain) {
            probeConnection(L, "sls_main", slsMain, windowIDs[i], transforms[i]);
        }
        if (cgsDefault && cgsDefault != cgsMain && cgsDefault != slsMain) {
            probeConnection(
                L, "cgs_default", cgsDefault, windowIDs[i], transforms[i]);
        }
        if (owner && owner != cgsMain && owner != slsMain &&
            owner != cgsDefault) {
            probeConnection(L, "owner", owner, windowIDs[i], transforms[i]);
        }

        lua_seti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "windows");
    free(windowIDs);
    free(transforms);
    return 1;
}

static bool transformsEqual(CGAffineTransform a, CGAffineTransform b) {
    const CGFloat tolerance = 0.01;
    return fabs(a.a - b.a) <= tolerance &&
           fabs(a.b - b.b) <= tolerance &&
           fabs(a.c - b.c) <= tolerance &&
           fabs(a.d - b.d) <= tolerance &&
           fabs(a.tx - b.tx) <= tolerance &&
           fabs(a.ty - b.ty) <= tolerance;
}

static CGError setSingularTransformsVerified(CGSConnectionID connection,
                                             const CGSWindowID *windowIDs,
                                             const CGAffineTransform *transforms,
                                             int count) {
    if (!setWindowTransform || !getWindowTransform || !getWindowBounds) {
        return kCGErrorFailure;
    }

    CGAffineTransform *previous =
        calloc((size_t)count, sizeof(*previous));
    CGAffineTransform *singular =
        calloc((size_t)count, sizeof(*singular));
    if (!previous || !singular) {
        free(previous);
        free(singular);
        return kCGErrorFailure;
    }

    CGError error = kCGErrorSuccess;
    int applied = 0;
    for (int i = 0; i < count; i++) {
        CGRect bounds = CGRectZero;
        error = getWindowBounds(connection, windowIDs[i], &bounds);
        if (error != kCGErrorSuccess) break;
        error = getWindowTransform(connection, windowIDs[i], &previous[i]);
        if (error != kCGErrorSuccess) break;

        CGFloat sx = transforms[i].a;
        CGFloat sy = transforms[i].d;
        if (!isfinite(sx) || !isfinite(sy) ||
            fabs(sx) < 0.000001 || fabs(sy) < 0.000001) {
            error = kCGErrorFailure;
            break;
        }

        // CGSSetWindowTransforms accepts the forward transform used by the
        // working batch path. The singular API instead maps screen pixels back
        // into the window buffer, so convert via the requested presented origin.
        CGFloat presentedX = (bounds.origin.x * sx) + transforms[i].tx;
        CGFloat presentedY = (bounds.origin.y * sy) + transforms[i].ty;
        singular[i] = CGAffineTransformMake(
            1.0 / sx, 0, 0, 1.0 / sy,
            -presentedX / sx, -presentedY / sy);

        error = setWindowTransform(connection, windowIDs[i], singular[i]);
        if (error != kCGErrorSuccess) break;
        applied = i + 1;

        CGAffineTransform readback = CGAffineTransformIdentity;
        error = getWindowTransform(connection, windowIDs[i], &readback);
        if (error != kCGErrorSuccess ||
            !transformsEqual(readback, singular[i])) {
            error = kCGErrorFailure;
            break;
        }
    }

    if (error != kCGErrorSuccess) {
        for (int i = 0; i < applied; i++) {
            setWindowTransform(connection, windowIDs[i], previous[i]);
        }
    }

    free(previous);
    free(singular);
    return error;
}

static bool sendDockTransforms(const CGSWindowID *windowIDs,
                               const CGAffineTransform *transforms,
                               const CGPoint *baseOrigins,
                               uint32_t count,
                               char *error,
                               size_t errorSize) {
    paperwm_injector_transform_t *items =
        calloc(count, sizeof(*items));
    if (!items) {
        snprintf(error, errorSize, "could not allocate Dock transform batch");
        return false;
    }

    CGSConnectionID connection = mainConnectionID();
    for (uint32_t i = 0; i < count; ++i) {
        CGPoint base = baseOrigins ? baseOrigins[i] : CGPointMake(NAN, NAN);
        if (!isfinite(base.x) || !isfinite(base.y)) {
            CGRect bounds = CGRectZero;
            CGError boundsError = getWindowBounds(
                connection, windowIDs[i], &bounds);
            if (boundsError != kCGErrorSuccess) {
                snprintf(error,
                         errorSize,
                         "could not read bounds for Dock transform window %d: CGError %d",
                         windowIDs[i],
                         boundsError);
                free(items);
                return false;
            }
            base = bounds.origin;
        }
        items[i].window_id = (uint32_t)windowIDs[i];
        items[i].base_x = base.x;
        items[i].base_y = base.y;
        items[i].sx = transforms[i].a;
        items[i].sy = transforms[i].d;
        items[i].tx = transforms[i].tx;
        items[i].ty = transforms[i].ty;
    }

    bool result = paperwm_injector_transform(
        getuid(), items, count, NULL, error, errorSize);
    free(items);
    return result;
}

static int windowCommit(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_checktype(L, 2, LUA_TTABLE);

    lua_Integer moveCount = luaL_len(L, 1);
    lua_Integer transformCount = luaL_len(L, 2);
    if (moveCount != transformCount) {
        lua_pushnil(L);
        lua_pushstring(L, "native commit move/transform counts do not match");
        return 2;
    }
    if (moveCount == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (transformRoute != NATIVE_ROUTE_DOCK &&
        moveRoute != NATIVE_ROUTE_DOCK) {
        lua_pushnil(L);
        lua_pushstring(L, "Dock atomic commit is not selected");
        return 2;
    }
    if (!dockHasCapability(PAPERWM_INJECTOR_CAP_COMMIT, false)) {
        lua_pushnil(L);
        lua_pushfstring(L,
                        "Dock payload does not support atomic commit: %s",
                        dockCapabilityError[0] ? dockCapabilityError :
                            "capability unavailable");
        return 2;
    }

    paperwm_injector_commit_t *commits =
        calloc((size_t)moveCount, sizeof(*commits));
    if (!commits) return luaL_error(L, "could not allocate native commit batch");

    for (lua_Integer i = 1; i <= moveCount; ++i) {
        lua_geti(L, 1, i);
        luaL_checktype(L, -1, LUA_TTABLE);
        lua_getfield(L, -1, "id");
        commits[i - 1].window_id = (uint32_t)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "x");
        commits[i - 1].x = luaL_checknumber(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "y");
        commits[i - 1].y = luaL_checknumber(L, -1);
        lua_pop(L, 1);
        lua_pop(L, 1);

        lua_geti(L, 2, i);
        luaL_checktype(L, -1, LUA_TTABLE);
        lua_getfield(L, -1, "id");
        uint32_t transformWindow =
            (uint32_t)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        if (transformWindow != commits[i - 1].window_id) {
            free(commits);
            return luaL_error(L, "native commit window order does not match");
        }
        lua_getfield(L, -1, "sx");
        commits[i - 1].sx = luaL_optnumber(L, -1, 1.0);
        lua_pop(L, 1);
        lua_getfield(L, -1, "sy");
        commits[i - 1].sy = luaL_optnumber(L, -1, 1.0);
        lua_pop(L, 1);
        lua_getfield(L, -1, "tx");
        commits[i - 1].tx = luaL_optnumber(L, -1, 0.0);
        lua_pop(L, 1);
        lua_getfield(L, -1, "ty");
        commits[i - 1].ty = luaL_optnumber(L, -1, 0.0);
        lua_pop(L, 1);
        lua_pop(L, 1);
    }

    char error[256] = {0};
    bool committed = paperwm_injector_commit(
        getuid(), commits, (uint32_t)moveCount, NULL, error, sizeof(error));
    free(commits);
    if (!committed) {
        invalidateDockCapabilities(error);
        lua_pushnil(L);
        lua_pushfstring(L, "Dock atomic commit failed: %s", error);
        return 2;
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int transformSetImpl(lua_State *L, bool atomic, bool singularOnly) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);

    lua_Integer count = luaL_len(L, 1);
    if (count == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }

    CGSWindowID *windowIDs = calloc((size_t)count, sizeof(*windowIDs));
    CGAffineTransform *transforms = calloc((size_t)count, sizeof(*transforms));
    CGPoint *baseOrigins = calloc((size_t)count, sizeof(*baseOrigins));
    if (!windowIDs || !transforms || !baseOrigins) {
        free(windowIDs);
        free(transforms);
        free(baseOrigins);
        return luaL_error(L, "could not allocate transform batch");
    }

    for (lua_Integer i = 1; i <= count; i++) {
        lua_geti(L, 1, i);
        luaL_checktype(L, -1, LUA_TTABLE);

        lua_getfield(L, -1, "id");
        windowIDs[i - 1] = (CGSWindowID)luaL_checkinteger(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, -1, "sx");
        CGFloat sx = (CGFloat)luaL_optnumber(L, -1, 1.0);
        lua_pop(L, 1);

        lua_getfield(L, -1, "sy");
        CGFloat sy = (CGFloat)luaL_optnumber(L, -1, 1.0);
        lua_pop(L, 1);

        lua_getfield(L, -1, "tx");
        CGFloat tx = (CGFloat)luaL_optnumber(L, -1, 0.0);
        lua_pop(L, 1);

        lua_getfield(L, -1, "ty");
        CGFloat ty = (CGFloat)luaL_optnumber(L, -1, 0.0);
        lua_pop(L, 1);

        baseOrigins[i - 1] = CGPointMake(NAN, NAN);
        lua_getfield(L, -1, "base_x");
        if (lua_isnumber(L, -1)) {
            baseOrigins[i - 1].x = (CGFloat)lua_tonumber(L, -1);
        }
        lua_pop(L, 1);
        lua_getfield(L, -1, "base_y");
        if (lua_isnumber(L, -1)) {
            baseOrigins[i - 1].y = (CGFloat)lua_tonumber(L, -1);
        }
        lua_pop(L, 1);

        transforms[i - 1] = CGAffineTransformMake(sx, 0, 0, sy, tx, ty);
        lua_pop(L, 1);
    }

    char dockError[256] = {0};
    if (transformRoute == NATIVE_ROUTE_DOCK ||
        transformRoute == NATIVE_ROUTE_UNAVAILABLE) {
        bool canTryDock = transformRoute == NATIVE_ROUTE_DOCK ||
            dockHasCapability(PAPERWM_INJECTOR_CAP_TRANSFORM, true);
        if (canTryDock && sendDockTransforms(
                windowIDs, transforms, baseOrigins, (uint32_t)count,
                dockError, sizeof(dockError))) {
            transformRoute = NATIVE_ROUTE_DOCK;
            free(windowIDs);
            free(transforms);
            free(baseOrigins);
            lua_pushboolean(L, 1);
            return 1;
        }
        if (canTryDock) invalidateDockCapabilities(dockError);
    }

    CGSConnectionID connection = mainConnectionID();
    CGError error = kCGErrorSuccess;
    if (singularOnly) {
        error = setSingularTransformsVerified(
            connection, windowIDs, transforms, (int)count);
    } else {
        if (atomic) error = disableUpdate(connection);
        if (error == kCGErrorSuccess) {
            error = setWindowTransforms(
                connection, windowIDs, transforms, (int)count);
            if (error != kCGErrorSuccess && !atomic) {
                error = setSingularTransformsVerified(
                    connection, windowIDs, transforms, (int)count);
            }
            if (atomic) {
                CGError enableError = reenableUpdate(connection);
                if (error == kCGErrorSuccess) error = enableError;
            }
        }
    }

    if (error == kCGErrorSuccess) {
        transformRoute = NATIVE_ROUTE_SKYLIGHT;
    } else if (dockHasCapability(PAPERWM_INJECTOR_CAP_TRANSFORM, true) &&
               sendDockTransforms(windowIDs,
                                  transforms,
                                  baseOrigins,
                                  (uint32_t)count,
                                  dockError,
                                  sizeof(dockError))) {
        transformRoute = NATIVE_ROUTE_DOCK;
        error = kCGErrorSuccess;
    } else {
        transformRoute = NATIVE_ROUTE_UNAVAILABLE;
    }
    free(windowIDs);
    free(transforms);
    free(baseOrigins);
    if (error != kCGErrorSuccess && dockError[0]) {
        lua_pushnil(L);
        lua_pushfstring(L,
                        "native transform unavailable: SkyLight CGError %d; "
                        "Dock: %s",
                        error,
                        dockError);
        return 2;
    }
    return pushCGError(L, error);
}

static int transformSet(lua_State *L) {
    return transformSetImpl(L, false, false);
}

static int transformSetAtomic(lua_State *L) {
    // Avoid a global WindowServer update lock in the interactive hot path.
    // The implementation still verifies any singular fallback by readback.
    return transformSetImpl(L, false, false);
}

static int transformSetSingular(lua_State *L) {
    return transformSetImpl(L, false, true);
}

static int transformBeginUpdates(lua_State *L) {
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);
    return pushCGError(L, disableUpdate(mainConnectionID()));
}

static int transformEndUpdates(lua_State *L) {
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);
    return pushCGError(L, reenableUpdate(mainConnectionID()));
}

static int hapticAvailable(lua_State *L) {
    @autoreleasepool {
        id<NSHapticFeedbackPerformer> performer =
            [NSHapticFeedbackManager defaultPerformer];
        lua_pushboolean(L, performer != nil);
    }
    return 1;
}

static int hapticPerform(lua_State *L) {
    @autoreleasepool {
        id<NSHapticFeedbackPerformer> performer =
            [NSHapticFeedbackManager defaultPerformer];
        if (!performer) {
            lua_pushnil(L);
            lua_pushstring(L, "no haptic feedback performer is available");
            return 2;
        }

        [performer performFeedbackPattern:NSHapticFeedbackPatternAlignment
                          performanceTime:NSHapticFeedbackPerformanceTimeNow];
    }
    lua_pushboolean(L, 1);
    return 1;
}

static const luaL_Reg transformFunctions[] = {
    {"available", transformAvailable},
    {"backendProbe", backendProbe},
    {"probe", transformProbe},
    {"bounds", windowBounds},
    {"move", windowMove},
    {"animate", windowAnimate},
    {"interactiveBegin", windowInteractiveBegin},
    {"interactiveUpdate", windowInteractiveUpdate},
    {"interactiveEnd", windowInteractiveEnd},
    {"commit", windowCommit},
    {"set", transformSet},
    {"setAtomic", transformSetAtomic},
    {"setSingular", transformSetSingular},
    {"beginUpdates", transformBeginUpdates},
    {"endUpdates", transformEndUpdates},
    {"hapticAvailable", hapticAvailable},
    {"haptic", hapticPerform},
    {"hidppMonitorStart", hidppMonitorStart},
    {"hidppMonitorPoll", hidppMonitorPoll},
    {"hidppMonitorStop", hidppMonitorStop},
    {NULL, NULL},
};

__attribute__((visibility("default")))
int luaopen_paperwm_transform(lua_State *L) {
    luaL_newlib(L, transformFunctions);
    return 1;
}
