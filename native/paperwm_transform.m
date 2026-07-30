#include <ApplicationServices/ApplicationServices.h>
#import <AppKit/NSHapticFeedback.h>
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include <lua.h>
#include <lauxlib.h>

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

static void setIntegerField(lua_State *L, const char *field, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, field);
}

static void setBooleanField(lua_State *L, const char *field, bool value) {
    lua_pushboolean(L, value);
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

static int transformSetImpl(lua_State *L, bool atomic) {
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

    CGSConnectionID connection = mainConnectionID();
    CGError error = kCGErrorSuccess;
    if (atomic) error = disableUpdate(connection);
    if (error == kCGErrorSuccess) {
        error = setWindowTransforms(connection, windowIDs, transforms, (int)count);
        if (error != kCGErrorSuccess && !atomic) {
            error = setSingularTransformsVerified(
                connection, windowIDs, transforms, (int)count);
        }
        if (atomic) {
            CGError enableError = reenableUpdate(connection);
            if (error == kCGErrorSuccess) error = enableError;
        }
    }
    free(windowIDs);
    free(transforms);
    return pushCGError(L, error);
}

static int transformSet(lua_State *L) {
    return transformSetImpl(L, false);
}

static int transformSetAtomic(lua_State *L) {
    // Avoid a global WindowServer update lock in the interactive hot path.
    // The implementation still verifies any singular fallback by readback.
    return transformSetImpl(L, false);
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
    {"probe", transformProbe},
    {"bounds", windowBounds},
    {"move", windowMove},
    {"set", transformSet},
    {"setAtomic", transformSetAtomic},
    {"beginUpdates", transformBeginUpdates},
    {"endUpdates", transformEndUpdates},
    {"hapticAvailable", hapticAvailable},
    {"haptic", hapticPerform},
    {NULL, NULL},
};

__attribute__((visibility("default")))
int luaopen_paperwm_transform(lua_State *L) {
    luaL_newlib(L, transformFunctions);
    return 1;
}
