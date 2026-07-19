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

static void *skyLight = NULL;
static CGSMainConnectionIDFn mainConnectionID = NULL;
static CGSSetWindowTransformsFn setWindowTransforms = NULL;
static CGSDisableUpdateFn disableUpdate = NULL;
static CGSReenableUpdateFn reenableUpdate = NULL;
static const char *loadError = NULL;

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

    if (!mainConnectionID || !setWindowTransforms || !disableUpdate || !reenableUpdate) {
        loadError = "required SkyLight symbols are unavailable";
        dlclose(skyLight);
        skyLight = NULL;
        return false;
    }
    return true;
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
