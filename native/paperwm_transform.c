#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

typedef int CGSConnectionID;
typedef int CGSWindowID;

typedef CGSConnectionID (*CGSMainConnectionIDFn)(void);
typedef CGError (*CGSSetWindowTransformsFn)(CGSConnectionID,
                                            const CGSWindowID *,
                                            const CGAffineTransform *,
                                            int);
typedef CGError (*CGSDisableUpdateFn)(CGSConnectionID);
typedef CGError (*CGSReenableUpdateFn)(CGSConnectionID);
typedef CGError (*CGSMoveWindowFn)(CGSConnectionID, CGSWindowID, const CGPoint *);

static void *skyLight = NULL;
static CGSMainConnectionIDFn mainConnectionID = NULL;
static CGSSetWindowTransformsFn setWindowTransforms = NULL;
static CGSDisableUpdateFn disableUpdate = NULL;
static CGSReenableUpdateFn reenableUpdate = NULL;
static CGSMoveWindowFn moveWindow = NULL;
static const char *loadError = NULL;

static int pushCGError(lua_State *L, CGError error);

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
    setWindowTransforms =
        (CGSSetWindowTransformsFn)dlsym(skyLight, "CGSSetWindowTransforms");
    disableUpdate = (CGSDisableUpdateFn)dlsym(skyLight, "CGSDisableUpdate");
    reenableUpdate = (CGSReenableUpdateFn)dlsym(skyLight, "CGSReenableUpdate");
    moveWindow = (CGSMoveWindowFn)dlsym(skyLight, "CGSMoveWindow");

    if (!mainConnectionID || !setWindowTransforms || !disableUpdate ||
        !reenableUpdate || !moveWindow) {
        loadError = "required SkyLight symbols are unavailable";
        dlclose(skyLight);
        skyLight = NULL;
        return false;
    }
    return true;
}

static int windowBounds(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_Integer count = luaL_len(L, 1);
    CFMutableArrayRef windowIDs = CFArrayCreateMutable(
        kCFAllocatorDefault, (CFIndex)count, &kCFTypeArrayCallBacks);
    if (!windowIDs) return luaL_error(L, "could not allocate window ID array");

    for (lua_Integer i = 1; i <= count; i++) {
        lua_geti(L, 1, i);
        int64_t windowID = (int64_t)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        CFNumberRef number = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberSInt64Type, &windowID);
        if (!number) {
            CFRelease(windowIDs);
            return luaL_error(L, "could not allocate window ID");
        }
        CFArrayAppendValue(windowIDs, number);
        CFRelease(number);
    }

    CFArrayRef descriptions = CGWindowListCreateDescriptionFromArray(windowIDs);
    CFRelease(windowIDs);
    if (!descriptions) {
        lua_newtable(L);
        return 1;
    }

    lua_createtable(L, (int)CFArrayGetCount(descriptions), 0);
    lua_Integer outputIndex = 1;
    for (CFIndex i = 0; i < CFArrayGetCount(descriptions); i++) {
        CFDictionaryRef description =
            (CFDictionaryRef)CFArrayGetValueAtIndex(descriptions, i);
        CFNumberRef number =
            (CFNumberRef)CFDictionaryGetValue(description, kCGWindowNumber);
        CFDictionaryRef boundsDictionary =
            (CFDictionaryRef)CFDictionaryGetValue(description, kCGWindowBounds);
        int64_t windowID = 0;
        CGRect bounds = CGRectZero;
        if (!number || !boundsDictionary ||
            !CFNumberGetValue(number, kCFNumberSInt64Type, &windowID) ||
            !CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds)) {
            continue;
        }

        lua_createtable(L, 0, 5);
        lua_pushinteger(L, (lua_Integer)windowID);
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
    CFRelease(descriptions);
    return 1;
}

static int windowMove(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);
    if (!moveWindow) {
        lua_pushnil(L);
        lua_pushstring(L, "CGSMoveWindow is unavailable");
        return 2;
    }

    lua_Integer count = luaL_len(L, 1);
    CGSConnectionID connection = mainConnectionID();
    for (lua_Integer i = 1; i <= count; i++) {
        lua_geti(L, 1, i);
        luaL_checktype(L, -1, LUA_TTABLE);

        lua_getfield(L, -1, "id");
        CGSWindowID windowID = (CGSWindowID)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "x");
        CGFloat x = (CGFloat)luaL_checknumber(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "y");
        CGFloat y = (CGFloat)luaL_checknumber(L, -1);
        lua_pop(L, 1);
        lua_pop(L, 1);

        CGPoint point = CGPointMake(x, y);
        CGError error = moveWindow(connection, windowID, &point);
        if (error != kCGErrorSuccess) return pushCGError(L, error);
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

static int transformSet(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);

    lua_Integer count = luaL_len(L, 1);
    if (count == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }

    CGSWindowID *windowIDs = calloc((size_t)count, sizeof(*windowIDs));
    CGAffineTransform *transforms = calloc((size_t)count, sizeof(*transforms));
    if (!windowIDs || !transforms) {
        free(windowIDs);
        free(transforms);
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

        transforms[i - 1] = CGAffineTransformMake(sx, 0, 0, sy, tx, ty);
        lua_pop(L, 1);
    }

    CGError error = setWindowTransforms(mainConnectionID(), windowIDs, transforms,
                                        (int)count);
    free(windowIDs);
    free(transforms);
    return pushCGError(L, error);
}

static int transformBeginUpdates(lua_State *L) {
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);
    return pushCGError(L, disableUpdate(mainConnectionID()));
}

static int transformEndUpdates(lua_State *L) {
    if (!loadSkyLight()) return luaL_error(L, "%s", loadError);
    return pushCGError(L, reenableUpdate(mainConnectionID()));
}

static const luaL_Reg transformFunctions[] = {
    {"available", transformAvailable},
    {"bounds", windowBounds},
    {"move", windowMove},
    {"set", transformSet},
    {"beginUpdates", transformBeginUpdates},
    {"endUpdates", transformEndUpdates},
    {NULL, NULL},
};

__attribute__((visibility("default")))
int luaopen_paperwm_transform(lua_State *L) {
    luaL_newlib(L, transformFunctions);
    return 1;
}
