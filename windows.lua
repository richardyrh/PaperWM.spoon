local Screen <const> = hs.screen
local Spaces <const> = hs.spaces
local Timer <const> = hs.timer
local Watcher <const> = hs.uielement.watcher
local Window <const> = hs.window

local Windows = {}
Windows.__index = Windows

-- A config reload can otherwise abandon a presentation transform owned by the
-- previous copy of this module.
if type(_G.PaperWMNativeAnimationCleanup) == "function" then
    pcall(_G.PaperWMNativeAnimationCleanup)
end
_G.PaperWMNativeAnimationCleanup = nil

-- hs.window's generic frame animator writes size, position, then size again on
-- every tick. PaperWM usually only changes a window's position while moving
-- focus, so use a single position write for that common path.
local position_animations = {}
local position_animation_timer = nil
local move_generations = {}
local focus_guard_target = nil
local focus_guard_timer = nil
local focus_guard_generation = 0
local default_animation_fps <const> = 120
local watcher_restart_padding <const> = 0.02
local default_animation_curve <const> = { 0.2, 0.0, 0.0, 1.0 }
local cached_curve = {}
local cached_curve_coefficients = nil

local function animationInterval()
    local fps = tonumber(Windows.PaperWM and Windows.PaperWM.animation_fps) or
        default_animation_fps
    if fps ~= fps or math.abs(fps) == math.huge or fps < 1 then
        fps = default_animation_fps
    end
    return 1 / fps
end

local function curveControlPoints()
    local curve = Windows.PaperWM and Windows.PaperWM.animation_curve or
        default_animation_curve
    local x1 = curve and (curve.x1 or curve[1])
    local y1 = curve and (curve.y1 or curve[2])
    local x2 = curve and (curve.x2 or curve[3])
    local y2 = curve and (curve.y2 or curve[4])

    if type(x1) ~= "number" or type(y1) ~= "number" or
        type(x2) ~= "number" or type(y2) ~= "number" or
        x1 ~= x1 or y1 ~= y1 or x2 ~= x2 or y2 ~= y2 or
        math.abs(x1) == math.huge or math.abs(y1) == math.huge or
        math.abs(x2) == math.huge or math.abs(y2) == math.huge or
        x1 < 0 or x1 > 1 or x2 < 0 or x2 > 1 then
        return table.unpack(default_animation_curve)
    end
    return x1, y1, x2, y2
end

local function curveCoefficients()
    local x1, y1, x2, y2 = curveControlPoints()
    if not cached_curve_coefficients or cached_curve[1] ~= x1 or
        cached_curve[2] ~= y1 or cached_curve[3] ~= x2 or cached_curve[4] ~= y2 then
        cached_curve = { x1, y1, x2, y2 }
        local cx, cy = 3 * x1, 3 * y1
        local bx, by = (3 * x2) - (2 * cx), (3 * y2) - (2 * cy)
        cached_curve_coefficients = {
            ax = 1 - cx - bx,
            bx = bx,
            cx = cx,
            ay = 1 - cy - by,
            by = by,
            cy = cy,
        }
    end
    return cached_curve_coefficients
end


local function sampleCurve(a, b, c, t)
    return ((a * t + b) * t + c) * t
end

local function sampleCurveDerivative(a, b, c, t)
    return (3 * a * t * t) + (2 * b * t) + c
end

local function easeProgress(progress)
    if progress <= 0 then return 0 end
    if progress >= 1 then return 1 end

    local coefficients = curveCoefficients()
    local t = progress

    -- Invert the curve's x coordinate so animation time maps to y. Newton's
    -- method handles the common case; bisection covers flat control points.
    for _ = 1, 5 do
        local error = sampleCurve(coefficients.ax, coefficients.bx,
            coefficients.cx, t) - progress
        if math.abs(error) < 0.00001 then break end
        local slope = sampleCurveDerivative(coefficients.ax, coefficients.bx,
            coefficients.cx, t)
        if math.abs(slope) < 0.000001 then break end
        local next_t = t - (error / slope)
        if next_t < 0 or next_t > 1 then break end
        t = next_t
    end

    if math.abs(sampleCurve(coefficients.ax, coefficients.bx,
            coefficients.cx, t) - progress) >= 0.00001 then
        local low, high = 0, 1
        for _ = 1, 12 do
            t = (low + high) / 2
            if sampleCurve(coefficients.ax, coefficients.bx,
                    coefficients.cx, t) < progress then
                low = t
            else
                high = t
            end
        end
    end

    return sampleCurve(coefficients.ay, coefficients.by, coefficients.cy, t)
end

local function watcherEvents()
    return { Watcher.windowMoved, Watcher.windowResized }
end

local function startWatcher(id, watcher, generation)
    if move_generations[id] == generation and
        Windows.PaperWM.state.ui_watchers[id] == watcher then
        watcher:start(watcherEvents())
    end
end

local function restartWatcherAfter(delay, id, watcher, generation)
    Timer.doAfter(delay, function()
        startWatcher(id, watcher, generation)
    end)
end

local function stopPositionAnimation(id)
    position_animations[id] = nil
    if position_animation_timer and not next(position_animations) then
        position_animation_timer:stop()
        position_animation_timer = nil
    end
end

local function stopAllPositionAnimations(set_real_positions)
    for id, animation in pairs(position_animations) do
        if set_real_positions then
            pcall(animation.window.setTopLeft, animation.window,
                animation.end_frame.x, animation.end_frame.y)
        end
        position_animations[id] = nil
        restartWatcherAfter(watcher_restart_padding, id,
            animation.watcher, animation.generation)
    end

    if position_animation_timer then
        position_animation_timer:stop()
        position_animation_timer = nil
    end
end

local function animatePositions()
    local now = Timer.secondsSinceEpoch()

    for id, animation in pairs(position_animations) do
        if move_generations[id] ~= animation.generation or
            Windows.PaperWM.state.ui_watchers[id] ~= animation.watcher then
            position_animations[id] = nil
        else
            local progress = math.min(1, (now - animation.started_at) / animation.duration)
            local eased = easeProgress(progress)
            local x = animation.start_frame.x +
                ((animation.end_frame.x - animation.start_frame.x) * eased)
            local y = animation.start_frame.y +
                ((animation.end_frame.y - animation.start_frame.y) * eased)
            local ok = pcall(animation.window.setTopLeft, animation.window, x, y)

            if not ok or progress >= 1 then
                position_animations[id] = nil
                restartWatcherAfter(watcher_restart_padding, id, animation.watcher,
                    animation.generation)
            end
        end
    end

    if not next(position_animations) and position_animation_timer then
        position_animation_timer:stop()
        position_animation_timer = nil
    end
end

local function animatePosition(window, start_frame, end_frame, watcher, generation)
    local id = window:id()
    position_animations[id] = {
        window = window,
        start_frame = start_frame,
        end_frame = end_frame,
        watcher = watcher,
        generation = generation,
        started_at = Timer.secondsSinceEpoch(),
        duration = Window.animationDuration,
    }

    if not position_animation_timer then
        position_animation_timer = Timer.new(animationInterval(), animatePositions)
        position_animation_timer:start()
    end
end

-- Optional native helper. It prefers direct SkyLight writes, can route rejected
-- writes through the injected Dock payload, and performs AppKit haptic feedback.
-- Accessibility remains only for permanent size changes and failure fallback.
local native_helper = nil
local native_helper_checked = false
local native_helper_error = nil
local native_transform = nil
local native_transform_checked = false
local native_transform_error = nil
local native_move_error = nil
local native_backend_selection = nil
local native_haptic = nil
local native_haptic_checked = false
local native_haptic_error = nil
local native_animations = {}
local native_animation_timer = nil
local native_animation_batch_timer = nil
local native_animation_completion_timer = nil
local native_animation_uses_payload = false
local scheduleNativeAnimationTransaction
local scheduleNativeAnimationCompletion
local animateNativeFrames
local interactive_moves = nil
local interactive_move_order = nil
local interactive_move_direct = false
local interactive_move_display_link = false
local quarantined_windows = {}
local interactive_profile = nil
local last_interactive_profile = nil
local native_animation_profile = nil
local last_native_animation_profile = nil
local pending_keyboard_navigation = nil

local function resetNativeBackendSelection()
    native_backend_selection = {
        checked = false,
        transform = false,
        move = false,
        interactive = false,
        reason = "native write capability has not been probed",
    }
end
resetNativeBackendSelection()

local function traceNativeAnimation(format, ...)
    local events = Windows.PaperWM and Windows.PaperWM.events
    if events and events.trace then events.trace(format, ...) end
end

local function beginNativeAnimationProfile()
    if native_animation_profile then return native_animation_profile end
    native_animation_profile = {
        started_at = Timer.absoluteTime(),
        backend = "setAtomic",
        window_ids = {},
        frames = 0,
        transactions = 0,
        total_skylight_ms = 0,
        max_skylight_ms = 0,
        total_commit_ms = 0,
        ax_position_calls = 0,
        ax_resize_calls = 0,
    }
    if pending_keyboard_navigation and
        pending_keyboard_navigation.focus_event_at then
        native_animation_profile.keyboard = pending_keyboard_navigation
        pending_keyboard_navigation = nil
    end
    return native_animation_profile
end

local function finishNativeAnimationProfile(status)
    local profile = native_animation_profile
    if not profile then return end

    local window_count = 0
    for _ in pairs(profile.window_ids) do window_count = window_count + 1 end
    profile.window_count = window_count
    profile.status = status
    profile.total_ms = (Timer.absoluteTime() - profile.started_at) / 1000000
    local native_call_count = profile.frames > 0 and profile.frames or
        profile.transactions
    profile.average_skylight_ms = native_call_count > 0 and
        (profile.total_skylight_ms / native_call_count) or 0
    local keyboard = profile.keyboard
    profile.keyboard_target = keyboard and keyboard.target or nil
    profile.request_to_animation_ms = keyboard and
        ((profile.started_at - keyboard.requested_at) / 1000000) or 0
    profile.request_to_focus_event_ms = keyboard and keyboard.focus_event_at and
        ((keyboard.focus_event_at - keyboard.requested_at) / 1000000) or 0
    profile.focus_call_ms = keyboard and keyboard.focus_call_ms or 0
    profile.layout_ms = keyboard and keyboard.layout_complete_at and
        ((keyboard.layout_complete_at - keyboard.focus_event_at) / 1000000) or 0
    profile.keyboard = nil
    profile.window_ids = nil
    last_native_animation_profile = profile
    native_animation_profile = nil

    traceNativeAnimation(
        "animation backend=%s status=%s target=%s windows=%d frames=%d transactions=%d request_to_event_ms=%.3f request_to_animation_ms=%.3f focus_call_ms=%.3f layout_ms=%.3f total_ms=%.3f first_frame_ms=%.3f skylight_avg_ms=%.3f skylight_max_ms=%.3f commit_ms=%.3f ax_position_calls=%d ax_resize_calls=%d transform_error=%s error=%s",
        tostring(profile.backend), tostring(profile.status),
        tostring(profile.keyboard_target),
        profile.window_count, profile.frames, profile.transactions,
        profile.request_to_focus_event_ms, profile.request_to_animation_ms,
        profile.focus_call_ms, profile.layout_ms, profile.total_ms,
        profile.first_frame_ms or 0,
        profile.average_skylight_ms, profile.max_skylight_ms,
        profile.total_commit_ms, profile.ax_position_calls,
        profile.ax_resize_calls, tostring(profile.transform_error),
        tostring(profile.error))
end

local function loadNativeHelper()
    if native_helper_checked then return native_helper end
    native_helper_checked = true
    if not hs.spoons or not hs.spoons.resourcePath then
        native_helper_error = "hs.spoons.resourcePath is unavailable"
        return nil
    end

    local path = hs.spoons.resourcePath("native/paperwm_transform.so")
    local loader, load_error = package.loadlib(path, "luaopen_paperwm_transform")
    if not loader then
        native_helper_error = load_error
        return nil
    end

    local loaded, helper = pcall(loader)
    if not loaded then
        native_helper_error = helper
        return nil
    end

    native_helper = helper
    return native_helper
end

local function loadNativeTransform()
    if native_transform_checked then return native_transform end
    native_transform_checked = true

    local helper = loadNativeHelper()
    if not helper then
        native_transform_error = native_helper_error
        return nil
    end

    local checked, available, reason = pcall(helper.available)
    if not checked or not available then
        native_transform_error = checked and reason or available
        return nil
    end

    native_transform = helper
    return native_transform
end

local function loadNativeHaptic()
    if native_haptic_checked then return native_haptic end
    native_haptic_checked = true

    local helper = loadNativeHelper()
    if not helper then
        native_haptic_error = native_helper_error
        return nil
    end

    if type(helper.hapticAvailable) ~= "function" or type(helper.haptic) ~= "function" then
        native_haptic_error = "native helper was built without haptic support"
        return nil
    end

    local checked, available, reason = pcall(helper.hapticAvailable)
    if not checked or not available then
        native_haptic_error = checked and
            (reason or "no haptic feedback performer is available") or available
        return nil
    end

    native_haptic = helper
    return native_haptic
end

local function nativeCall(method, ...)
    local transform = loadNativeTransform()
    if not transform then return false, native_transform_error end

    local called, result, reason = pcall(transform[method], ...)
    if not called then return false, result end
    if not result then return false, reason end
    if method == "set" or method == "setAtomic" or method == "setSingular" then
        native_transform_error = nil
    end
    return true, result
end

local function nativeHelperCall(method, ...)
    local helper = loadNativeHelper()
    if not helper then return false, native_helper_error end
    if type(helper[method]) ~= "function" then
        return false, string.format("native helper has no %s operation", method)
    end

    local called, result, reason = pcall(helper[method], ...)
    if not called then return false, result end
    if not result then return false, reason end
    if method == "move" then native_move_error = nil end
    return true, result
end

local function nativeCapabilityIDs(preferred)
    local ids, seen = {}, {}
    for _, id in ipairs(preferred or {}) do
        if id and not seen[id] then
            table.insert(ids, id)
            seen[id] = true
        end
    end
    local remaining = {}
    local state = Windows.PaperWM and Windows.PaperWM.state
    for id in pairs((state and state.index_table) or {}) do
        if not seen[id] then table.insert(remaining, id) end
    end
    table.sort(remaining)
    for _, id in ipairs(remaining) do table.insert(ids, id) end
    return ids
end

local function selectNativeBackends(preferred)
    local selection = native_backend_selection
    if selection.checked then return selection end
    if not Windows.PaperWM or Windows.PaperWM.animation_backend ~= "native" then
        selection.reason = "native animation backend is not configured"
        return selection
    end

    local helper = loadNativeHelper()
    if not helper then
        selection.checked = true
        selection.reason = native_helper_error
        return selection
    end

    -- Old helpers do not have the write probe. Preserve their original
    -- behavior so a source update does not disable a known-working macOS 26
    -- helper before it is rebuilt.
    if type(helper.backendProbe) ~= "function" then
        selection.checked = true
        selection.legacy = true
        selection.transform = loadNativeTransform() ~= nil
        selection.move = type(helper.bounds) == "function" and
            type(helper.move) == "function"
        selection.interactive = false
        selection.reason = "legacy helper; using symbol-based selection"
        return selection
    end

    local called, result = pcall(helper.backendProbe,
        nativeCapabilityIDs(preferred))
    if not called or type(result) ~= "table" then
        selection.checked = true
        selection.reason = called and "native capability probe returned no result" or
            tostring(result)
        native_transform_error = selection.reason
        native_move_error = selection.reason
        return selection
    end
    if not result.checked then
        selection.reason = result.reason or
            "no foreign managed window is available to probe"
        return selection
    end

    selection.checked = true
    selection.window_id = result.window_id
    selection.owner_connection = result.owner_connection
    selection.main_connection = result.main_connection
    selection.transform = result.transform == true
    selection.move = result.move == true
    selection.animation = result.animation == true
    selection.interactive = result.interactive == true
    selection.transform_mode = result.transform_mode
    selection.transform_backend = result.transform_backend
    selection.move_backend = result.move_backend
    selection.dock_capabilities = result.dock_capabilities
    selection.dock_error = result.dock_error
    selection.transform_error = result.transform_error
    selection.move_error = result.move_error
    selection.reason = nil

    if selection.transform then
        native_transform_error = nil
        loadNativeTransform()
    else
        native_transform_error = string.format(
            "native transform unavailable for foreign window %d (error %s)",
            result.window_id, tostring(result.transform_error))
    end
    if selection.move then
        native_move_error = nil
    else
        native_move_error = string.format(
            "native position write unavailable for foreign window %d (error %s)",
            result.window_id, tostring(result.move_error))
    end

    traceNativeAnimation(
        "backend selected transform=%s transform_backend=%s transform_mode=%s move=%s move_backend=%s display_link_animation=%s display_link_interactive=%s window=%s owner=%s main=%s transform_error=%s move_error=%s dock_error=%s",
        tostring(selection.transform), tostring(selection.transform_backend),
        tostring(selection.transform_mode), tostring(selection.move),
        tostring(selection.move_backend), tostring(selection.animation),
        tostring(selection.interactive),
        tostring(selection.window_id), tostring(selection.owner_connection),
        tostring(selection.main_connection), tostring(selection.transform_error),
        tostring(selection.move_error), tostring(selection.dock_error))
    return selection
end

local function nativeSet(transforms)
    local helper = loadNativeHelper()
    local selection = selectNativeBackends()
    if selection.transform_mode == "singular" and helper and
        type(helper.setSingular) == "function" then
        return nativeHelperCall("setSingular", transforms)
    end
    return nativeCall("set", transforms)
end

local function nativeSetAtomic(transforms)
    local helper = loadNativeHelper()
    local selection = selectNativeBackends()
    if selection.transform_mode == "singular" and helper and
        type(helper.setSingular) == "function" then
        return nativeHelperCall("setSingular", transforms)
    end
    return nativeCall("setAtomic", transforms)
end

local function nativeAnimate(animations)
    return nativeHelperCall("animate", animations)
end

local function nativeDisplayLinkEnabled()
    local selection = selectNativeBackends()
    local helper = loadNativeHelper()
    return selection.transform_backend == "dock" and
        selection.animation == true and helper ~= nil and
        type(helper.animate) == "function"
end

local function nativeInteractiveDisplayLinkEnabled()
    local selection = selectNativeBackends()
    local helper = loadNativeHelper()
    return selection.interactive == true and helper ~= nil and
        type(helper.interactiveBegin) == "function" and
        type(helper.interactiveUpdate) == "function" and
        type(helper.interactiveEnd) == "function"
end

local function nativeBounds(id)
    local ok, bounds = nativeHelperCall("bounds", { id })
    if not ok or not bounds or not bounds[1] then return nil, bounds end
    local frame = bounds[1]
    return hs.geometry.rect(frame.x, frame.y, frame.w, frame.h)
end

local function nativeBoundsBatch(items)
    local ids = {}
    for _, item in ipairs(items) do table.insert(ids, item.window:id()) end

    local ok, bounds = nativeHelperCall("bounds", ids)
    if not ok then return {}, bounds end

    local frames = {}
    for _, frame in ipairs(bounds or {}) do
        frames[frame.id] = hs.geometry.rect(frame.x, frame.y, frame.w, frame.h)
    end
    return frames, nil
end

local function sizesMatch(a, b)
    return a and math.abs(a.w - b.w) <= 1 and math.abs(a.h - b.h) <= 1
end

local function framesMatch(a, b)
    return a and sizesMatch(a, b) and
        math.abs(a.x - b.x) <= 1 and math.abs(a.y - b.y) <= 1
end

local function targetTransform(record, real_frame)
    local sx = record.end_frame.w / real_frame.w
    local sy = record.end_frame.h / real_frame.h
    return {
        id = record.id,
        sx = sx,
        sy = sy,
        tx = record.end_frame.x - (real_frame.x * sx),
        ty = record.end_frame.y - (real_frame.y * sy),
    }
end

local function identityTransforms(records)
    local transforms = {}
    for _, animation in ipairs(records) do
        table.insert(transforms, { id = animation.id, sx = 1, sy = 1, tx = 0, ty = 0 })
    end
    return transforms
end

local function commitNativePositions(records)
    local moves = {}
    for _, record in ipairs(records) do
        table.insert(moves, {
            id = record.id,
            x = record.end_frame.x,
            y = record.end_frame.y,
        })
    end

    local identities = identityTransforms(records)
    local helper = loadNativeHelper()
    if helper and type(helper.commit) == "function" then
        local committed = nativeHelperCall("commit", moves, identities)
        if committed then return true, nil end
    end

    local updates_disabled = nativeCall("beginUpdates")
    local moved, move_error = nativeCall("move", moves)
    local reset_ok, reset_error = false, nil
    if moved then
        reset_ok, reset_error = nativeSet(identities)
    end
    if updates_disabled then nativeCall("endUpdates") end

    return moved and reset_ok, move_error or reset_error
end

local function settleNativeRecord(record, real_frame)
    local committed, commit_error = commitNativePositions({ record })
    if committed then return true end

    -- Keep AX as a bounded fallback when WindowServer rejects the permanent
    -- move. Intermediate animation frames never use this path.
    if native_animation_profile then
        native_animation_profile.ax_position_calls =
            native_animation_profile.ax_position_calls + 1
    end
    local positioned, position_result = pcall(
        record.window.setTopLeft, record.window,
        record.end_frame.x, record.end_frame.y)
    positioned = positioned and position_result ~= false
    local reset_ok, reset_error = nativeSet(identityTransforms({ record }))
    if positioned and reset_ok then return true end

    if not positioned and real_frame and real_frame.w > 0 and real_frame.h > 0 then
        nativeSet({ targetTransform(record, real_frame) })
    end
    return false, commit_error or
        (not positioned and position_result) or reset_error
end

local function abandonNativeRecord(record, reason)
    quarantined_windows[record.id] = nil
    nativeSet(identityTransforms({ record }))
    restartWatcherAfter(watcher_restart_padding, record.id,
        record.watcher, record.generation)
    if Windows.PaperWM then
        Windows.PaperWM.logger.wf(
            "window %d native commit abandoned: %s",
            record.id, tostring(reason or "Accessibility size did not converge"))
    end
end

local function commitNativeRecord(record)
    local real_frame, bounds_error = nativeBounds(record.id)
    if not real_frame then
        record.missing_count = (record.missing_count or 0) + 1
        if record.missing_count >= 3 then
            nativeSet(identityTransforms({ record }))
            quarantined_windows[record.id] = nil
            return true
        end
        abandonNativeRecord(record, bounds_error)
        return false
    end
    record.missing_count = 0
    if real_frame.w <= 0 or real_frame.h <= 0 then
        abandonNativeRecord(record, "WindowServer reported empty bounds")
        return false
    end

    nativeSet({ targetTransform(record, real_frame) })
    if not sizesMatch(real_frame, record.end_frame) then
        -- This is deliberately the only AX operation in the native commit path.
        -- hs.window.timeout bounds how long an unresponsive app can hold us here.
        if native_animation_profile then
            native_animation_profile.ax_resize_calls =
                native_animation_profile.ax_resize_calls + 1
        end
        local resized, resize_error = pcall(record.window.setSize, record.window,
            record.end_frame.w, record.end_frame.h)
        local resized_frame = nativeBounds(record.id)
        if resized_frame then real_frame = resized_frame end
        if not resized or not sizesMatch(real_frame, record.end_frame) then
            abandonNativeRecord(record, resize_error)
            return false
        end
    end

    local settled, settle_error = settleNativeRecord(record, real_frame)
    if not settled then
        abandonNativeRecord(record, settle_error)
        return false
    end
    quarantined_windows[record.id] = nil
    return true
end

local function commitNativeAnimations(records, set_real_positions)
    if #records == 0 then return end
    local commit_started = Timer.absoluteTime()

    for _, animation in ipairs(records) do
        native_animations[animation.id] = nil
        if animation.direct then
            local target = set_real_positions and animation.end_frame or
                animation.real_frame
            local moved, move_error = nativeHelperCall("move", { {
                id = animation.id,
                x = target.x,
                y = target.y,
            } })
            if not moved then
                if native_animation_profile then
                    native_animation_profile.ax_position_calls =
                        native_animation_profile.ax_position_calls + 1
                end
                local positioned, result = pcall(
                    animation.window.setTopLeft, animation.window,
                    target.x, target.y)
                positioned = positioned and result ~= false
                if not positioned and Windows.PaperWM then
                    Windows.PaperWM.logger.ef(
                        "could not commit direct native move for window %d: %s",
                        animation.id, tostring(move_error or result))
                end
            end
            restartWatcherAfter(watcher_restart_padding, animation.id,
                animation.watcher, animation.generation)
        elseif set_real_positions then
            if commitNativeRecord(animation) then
                restartWatcherAfter(watcher_restart_padding, animation.id,
                    animation.watcher, animation.generation)
            end
        else
            local reset_ok, reset_error = nativeSet(identityTransforms({ animation }))
            if not reset_ok and Windows.PaperWM then
                Windows.PaperWM.logger.ef(
                    "could not reset native transform: %s", reset_error)
            end
            restartWatcherAfter(watcher_restart_padding, animation.id,
                animation.watcher, animation.generation)
        end
    end
    if native_animation_profile then
        native_animation_profile.total_commit_ms =
            native_animation_profile.total_commit_ms +
            ((Timer.absoluteTime() - commit_started) / 1000000)
    end
end

local function finishNativePayloadRecords(records)
    if #records == 0 then return end
    local frames = nativeBoundsBatch(records)
    local fallback = {}

    for _, record in ipairs(records) do
        if record.payload_auto_commit and
            framesMatch(frames[record.id], record.end_frame) then
            native_animations[record.id] = nil
            quarantined_windows[record.id] = nil
            restartWatcherAfter(watcher_restart_padding, record.id,
                record.watcher, record.generation)
        else
            table.insert(fallback, record)
        end
    end
    commitNativeAnimations(fallback, true)
end


local function updateNativeAnimationState(animation, now)
    if animation.pending_transaction then return 0 end
    local progress = animation.duration > 0 and
        math.min(1, math.max(0,
            (now - animation.started_at) / animation.duration)) or 1
    local eased = easeProgress(progress)
    animation.x = animation.start_x +
        ((animation.end_frame.x - animation.start_x) * eased)
    animation.y = animation.start_y +
        ((animation.end_frame.y - animation.start_y) * eased)
    animation.sx = animation.start_sx +
        ((animation.end_sx - animation.start_sx) * eased)
    animation.sy = animation.start_sy +
        ((animation.end_sy - animation.start_sy) * eased)
    animation.tx = animation.x - (animation.real_frame.x * animation.sx)
    animation.ty = animation.y - (animation.real_frame.y * animation.sy)
    return progress
end

local function updateAllNativeAnimationStates()
    local now = Timer.secondsSinceEpoch()
    for _, animation in pairs(native_animations) do
        updateNativeAnimationState(animation, now)
    end
end

local function stopNativeLifecycleTimers()
    if native_animation_batch_timer then
        native_animation_batch_timer:stop()
        native_animation_batch_timer = nil
    end
    if native_animation_completion_timer then
        native_animation_completion_timer:stop()
        native_animation_completion_timer = nil
    end
end

local function cancelNativePayloadAnimation()
    if not native_animation_uses_payload then return true, nil end
    local cancelled, reason = nativeAnimate({})
    native_animation_uses_payload = false
    return cancelled, reason
end

local function stopNativeAnimation(id, set_real_position)
    local animation = native_animations[id]
    if native_animation_uses_payload then
        updateAllNativeAnimationStates()
        cancelNativePayloadAnimation()
        stopNativeLifecycleTimers()
    end
    if animation then commitNativeAnimations({ animation }, set_real_position) end

    if not next(native_animations) then
        if native_animation_timer then
            native_animation_timer:stop()
            native_animation_timer = nil
        end
        stopNativeLifecycleTimers()
        if animation then finishNativeAnimationProfile("stopped") end
    elseif nativeDisplayLinkEnabled() then
        scheduleNativeAnimationTransaction()
    end
end

local function stopAllNativeAnimations(set_real_positions)
    local animations = {}
    for _, animation in pairs(native_animations) do table.insert(animations, animation) end
    cancelNativePayloadAnimation()
    stopNativeLifecycleTimers()
    commitNativeAnimations(animations, set_real_positions)
    if native_animation_timer then
        native_animation_timer:stop()
        native_animation_timer = nil
    end
    if #animations > 0 then finishNativeAnimationProfile("stopped") end
end

-- Take ownership of position-only native animations without resetting their
-- presentation transforms. This lets a new gesture interrupt a layout snap at
-- the exact frame currently visible on screen.
local function adoptNativeAnimationFrames(items)
    if not next(native_animations) then return nil, nil, false end

    if native_animation_uses_payload then
        updateAllNativeAnimationStates()
        cancelNativePayloadAnimation()
        stopNativeLifecycleTimers()
    end

    local frames, real_frames = {}, {}
    local adopted = {}
    for _, item in ipairs(items) do
        local animation = native_animations[item.window:id()]
        if animation then
            if math.abs(animation.sx - 1) > 0.001 or
                math.abs(animation.sy - 1) > 0.001 or
                not sizesMatch(animation.real_frame, animation.end_frame) then
                if nativeDisplayLinkEnabled() then
                    scheduleNativeAnimationTransaction()
                end
                return nil, nil, true
            end

            frames[animation.id] = hs.geometry.rect(
                animation.x, animation.y,
                animation.real_frame.w, animation.real_frame.h)
            if animation.direct then
                real_frames[animation.id] = hs.geometry.rect(
                    animation.x, animation.y,
                    animation.real_frame.w, animation.real_frame.h)
            else
                real_frames[animation.id] = hs.geometry.rect(
                    animation.real_frame.x, animation.real_frame.y,
                    animation.real_frame.w, animation.real_frame.h)
            end
            table.insert(adopted, animation)
        end
    end
    if #adopted == 0 then
        if nativeDisplayLinkEnabled() then scheduleNativeAnimationTransaction() end
        return nil, nil, false
    end

    for _, animation in ipairs(adopted) do
        native_animations[animation.id] = nil
    end
    if not next(native_animations) then
        if native_animation_timer then
            native_animation_timer:stop()
            native_animation_timer = nil
        end
        stopNativeLifecycleTimers()
        finishNativeAnimationProfile("adopted")
    elseif nativeDisplayLinkEnabled() then
        scheduleNativeAnimationTransaction()
    end
    return frames, real_frames, false
end

local function recordNativeAnimationCall(call_started, backend)
    if not native_animation_profile then return end
    local profile = native_animation_profile
    local skylight_ms = (Timer.absoluteTime() - call_started) / 1000000
    profile.backend = backend
    profile.frames = profile.frames + 1
    profile.total_skylight_ms = profile.total_skylight_ms + skylight_ms
    profile.max_skylight_ms = math.max(profile.max_skylight_ms, skylight_ms)
    if not profile.first_frame_ms then
        profile.first_frame_ms =
            (call_started - profile.started_at) / 1000000
    end
end

local function recordNativeAnimationTransaction(call_started)
    if not native_animation_profile then return end
    local profile = native_animation_profile
    local native_ms = (Timer.absoluteTime() - call_started) / 1000000
    profile.backend = "dockDisplayLink"
    profile.transactions = profile.transactions + 1
    profile.total_skylight_ms = profile.total_skylight_ms + native_ms
    profile.max_skylight_ms = math.max(profile.max_skylight_ms, native_ms)
    if not profile.first_frame_ms then
        -- The first transform is applied by the next display refresh. Record
        -- submission latency here; exact display cadence is logged by Dock.
        profile.first_frame_ms =
            (call_started - profile.started_at) / 1000000
    end
end

local function startNativeAnimationTransaction()
    native_animation_batch_timer = nil
    if not next(native_animations) then return end

    local abandoned = {}
    for id, animation in pairs(native_animations) do
        if move_generations[id] ~= animation.generation or
            Windows.PaperWM.state.ui_watchers[id] ~= animation.watcher then
            table.insert(abandoned, animation)
        end
    end
    if #abandoned > 0 then
        updateAllNativeAnimationStates()
        cancelNativePayloadAnimation()
        commitNativeAnimations(abandoned, false)
    end
    if not next(native_animations) then
        finishNativeAnimationProfile("abandoned")
        return
    end

    local now = Timer.secondsSinceEpoch()
    local x1, y1, x2, y2 = curveControlPoints()
    local animations = {}
    for _, animation in pairs(native_animations) do
        if animation.pending_transaction then
            animation.pending_transaction = false
            animation.started_at = now
            animation.duration = Window.animationDuration
        else
            updateNativeAnimationState(animation, now)
        end
        table.insert(animations, {
            id = animation.id,
            direct = animation.direct,
            auto_commit = animation.payload_auto_commit and
                not animation.direct,
            start_x = animation.x,
            start_y = animation.y,
            end_x = animation.end_frame.x,
            end_y = animation.end_frame.y,
            start_sx = animation.sx,
            start_sy = animation.sy,
            end_sx = animation.end_sx,
            end_sy = animation.end_sy,
            duration = math.max(0.001,
                (animation.started_at + animation.duration) - now),
            curve_x1 = x1,
            curve_y1 = y1,
            curve_x2 = x2,
            curve_y2 = y2,
        })
    end

    local call_started = Timer.absoluteTime()
    local started, reason = nativeAnimate(animations)
    recordNativeAnimationTransaction(call_started)
    if started then
        native_animation_uses_payload = true
        scheduleNativeAnimationCompletion()
        return
    end

    native_animation_uses_payload = false
    native_backend_selection.animation = false
    if native_animation_profile then
        native_animation_profile.error = reason
    end
    Windows.PaperWM.logger.wf(
        "Dock display-link animation failed; using legacy native timer: %s",
        tostring(reason))
    if not native_animation_timer then
        native_animation_timer = Timer.new(animationInterval(), animateNativeFrames)
        native_animation_timer:start()
    end
end

scheduleNativeAnimationCompletion = function()
    if native_animation_completion_timer then
        native_animation_completion_timer:stop()
        native_animation_completion_timer = nil
    end
    if not next(native_animations) then return end

    local next_completion = math.huge
    for _, animation in pairs(native_animations) do
        next_completion = math.min(next_completion,
            animation.started_at + animation.duration)
    end
    local padding = math.max(0.01, animationInterval() * 2)
    local delay = math.max(0.001,
        next_completion + padding - Timer.secondsSinceEpoch())
    native_animation_completion_timer = Timer.doAfter(delay, function()
        native_animation_completion_timer = nil
        local now = Timer.secondsSinceEpoch()
        local finished = {}
        local active_count = 0
        for _, animation in pairs(native_animations) do
            updateNativeAnimationState(animation, now)
            active_count = active_count + 1
            if now >= animation.started_at + animation.duration + padding then
                table.insert(finished, animation)
            end
        end

        if #finished == 0 then
            scheduleNativeAnimationCompletion()
            return
        end

        if #finished < active_count then
            cancelNativePayloadAnimation()
        else
            -- The payload has applied each final transform and stopped its
            -- display link before this padded completion callback runs.
            native_animation_uses_payload = false
        end
        finishNativePayloadRecords(finished)

        if next(native_animations) then
            scheduleNativeAnimationTransaction()
        else
            finishNativeAnimationProfile("complete")
        end
    end)
end

scheduleNativeAnimationTransaction = function()
    if native_animation_completion_timer then
        native_animation_completion_timer:stop()
        native_animation_completion_timer = nil
    end
    if native_animation_batch_timer then return end
    native_animation_batch_timer = Timer.doAfter(0, startNativeAnimationTransaction)
end

animateNativeFrames = function()
    local now = Timer.secondsSinceEpoch()
    local transforms, transform_records, moves = {}, {}, {}
    local finished, abandoned = {}, {}

    for id, animation in pairs(native_animations) do
        if move_generations[id] ~= animation.generation or
            Windows.PaperWM.state.ui_watchers[id] ~= animation.watcher then
            table.insert(abandoned, animation)
        else
            local progress = math.min(1, (now - animation.started_at) / animation.duration)
            local eased = easeProgress(progress)
            animation.x = animation.start_x + ((animation.end_frame.x - animation.start_x) * eased)
            animation.y = animation.start_y + ((animation.end_frame.y - animation.start_y) * eased)
            animation.sx = animation.start_sx + ((animation.end_sx - animation.start_sx) * eased)
            animation.sy = animation.start_sy + ((animation.end_sy - animation.start_sy) * eased)

            -- CGS applies the affine transform in global screen coordinates.
            -- Offset scaling around the origin so the presented top-left follows
            -- the independently interpolated x/y path.
            animation.tx = animation.x - (animation.real_frame.x * animation.sx)
            animation.ty = animation.y - (animation.real_frame.y * animation.sy)
            if animation.direct then
                table.insert(moves, {
                    id = id,
                    x = animation.x,
                    y = animation.y,
                })
            else
                table.insert(transforms, {
                    id = id,
                    base_x = animation.real_frame.x,
                    base_y = animation.real_frame.y,
                    sx = animation.sx,
                    sy = animation.sy,
                    tx = animation.tx,
                    ty = animation.ty,
                })
                table.insert(transform_records, animation)
            end
            if progress >= 1 then table.insert(finished, animation) end
        end
    end

    if #abandoned > 0 then commitNativeAnimations(abandoned, false) end

    if #moves > 0 then
        local call_started = Timer.absoluteTime()
        local moved, reason = nativeHelperCall("move", moves)
        recordNativeAnimationCall(call_started, "move")
        if not moved then
            native_move_error = reason
            if native_animation_profile then native_animation_profile.error = reason end
            stopAllNativeAnimations(true)
            Windows.PaperWM.logger.ef(
                "direct native animation failed; falling back to Accessibility: %s",
                reason)
            return
        end
    end

    if #transforms > 0 then
        local call_started = Timer.absoluteTime()
        local transformed, reason = nativeSetAtomic(transforms)
        recordNativeAnimationCall(call_started, "setAtomic")
        if transformed and native_animation_profile then
            native_animation_profile.successful_transform_frames =
                (native_animation_profile.successful_transform_frames or 0) + 1
        end
        if not transformed then
            native_transform_error = reason
            if native_animation_profile then
                native_animation_profile.transform_error = reason
            end

            -- Preserve the transform backend on systems where it works. If it
            -- is rejected at runtime, position-only animations can continue on
            -- the same direct CGSMoveWindow path used by trackpad gestures.
            local fallback_moves = {}
            local selection = selectNativeBackends()
            local helper = loadNativeHelper()
            local can_move_directly = selection.move and
                native_move_error == nil and helper ~= nil and
                type(helper.move) == "function"
            for _, animation in ipairs(transform_records) do
                can_move_directly = can_move_directly and
                    sizesMatch(animation.real_frame, animation.end_frame)
                table.insert(fallback_moves, {
                    id = animation.id,
                    x = animation.x,
                    y = animation.y,
                })
            end

            local moved, move_reason = false, nil
            if can_move_directly then
                -- Clear presentation state only if an earlier frame succeeded.
                -- A first-frame rejection did not establish transforms and
                -- should transfer directly without touching the singular API.
                if native_animation_profile and
                    (native_animation_profile.successful_transform_frames or 0) > 0 then
                    nativeSet(identityTransforms(transform_records))
                end
                local move_started = Timer.absoluteTime()
                moved, move_reason = nativeHelperCall("move", fallback_moves)
                recordNativeAnimationCall(move_started, "setAtomic->move")
            end
            if moved then
                for _, animation in ipairs(transform_records) do
                    animation.direct = true
                end
            else
                if move_reason then native_move_error = move_reason end
                if native_animation_profile then
                    native_animation_profile.error = move_reason or reason
                end
                stopAllNativeAnimations(true)
                Windows.PaperWM.logger.ef(
                    "native animation failed; falling back to Accessibility: %s",
                    move_reason or reason)
                return
            end
        end
    end

    if #finished > 0 then commitNativeAnimations(finished, true) end

    if not next(native_animations) and native_animation_timer then
        native_animation_timer:stop()
        native_animation_timer = nil
        finishNativeAnimationProfile("complete")
    end
end

local function animateNativeFrame(window, real_frame, end_frame, watcher, generation, direct)
    local id = window:id()
    local use_display_link = nativeDisplayLinkEnabled()
    local profile = beginNativeAnimationProfile()
    profile.window_ids[id] = true
    local previous = native_animations[id]
    if previous then
        updateNativeAnimationState(previous, Timer.secondsSinceEpoch())
    end
    local quarantined = quarantined_windows[id]
    local start_x = previous and previous.x or
        (quarantined and quarantined.end_frame.x or real_frame.x)
    local start_y = previous and previous.y or
        (quarantined and quarantined.end_frame.y or real_frame.y)
    local start_sx = previous and previous.sx or
        (quarantined and quarantined.end_frame.w / real_frame.w or 1)
    local start_sy = previous and previous.sy or
        (quarantined and quarantined.end_frame.h / real_frame.h or 1)
    quarantined_windows[id] = nil

    native_animations[id] = {
        id = id,
        window = window,
        real_frame = real_frame,
        end_frame = end_frame,
        watcher = watcher,
        generation = generation,
        direct = direct == true,
        payload_auto_commit = direct == true or sizesMatch(real_frame, end_frame),
        start_x = start_x,
        start_y = start_y,
        start_sx = start_sx,
        start_sy = start_sy,
        end_sx = end_frame.w / real_frame.w,
        end_sy = end_frame.h / real_frame.h,
        x = start_x,
        y = start_y,
        sx = start_sx,
        sy = start_sy,
        tx = start_x - (real_frame.x * start_sx),
        ty = start_y - (real_frame.y * start_sy),
        started_at = Timer.secondsSinceEpoch(),
        duration = Window.animationDuration,
        pending_transaction = use_display_link,
    }

    if use_display_link then
        scheduleNativeAnimationTransaction()
    elseif not native_animation_timer then
        native_animation_timer = Timer.new(animationInterval(), animateNativeFrames)
        native_animation_timer:start()
    end
end

local function nativeBackendEnabled(preferred)
    local selection = selectNativeBackends(preferred)
    return Windows.PaperWM.animation_backend == "native" and
        selection.transform and
        loadNativeTransform() ~= nil
end

local function nativeMoveBackendEnabled(preferred)
    if Windows.PaperWM.animation_backend ~= "native" then
        return false
    end
    local selection = selectNativeBackends(preferred)
    if not selection.move then return false end
    local helper = loadNativeHelper()
    return helper ~= nil and type(helper.bounds) == "function" and
        type(helper.move) == "function"
end

local function nativeBoundsBackendEnabled()
    if not Windows.PaperWM or Windows.PaperWM.animation_backend ~= "native" then
        return false
    end
    local helper = loadNativeHelper()
    return helper ~= nil and type(helper.bounds) == "function"
end

---record delivery of the focus event that starts a keyboard layout transition
---@param window Window
function Windows.noteKeyboardFocusEvent(window)
    local navigation = pending_keyboard_navigation
    if navigation and navigation.target == window:id() then
        navigation.focus_event_at = Timer.absoluteTime()
    end
end

---record completion of the synchronous layout pass after a keyboard focus event
---@param window Window
function Windows.noteKeyboardLayoutComplete(window)
    local id = window:id()
    local navigation = native_animation_profile and native_animation_profile.keyboard
    if not navigation or navigation.target ~= id then
        navigation = pending_keyboard_navigation
    end
    if not navigation or navigation.target ~= id then return end

    navigation.layout_complete_at = Timer.absoluteTime()
    if not native_animation_profile then
        pending_keyboard_navigation = nil
        local backend = next(position_animations) and "accessibility" or "none"
        traceNativeAnimation(
            "animation backend=%s status=scheduled target=%d request_to_event_ms=%.3f focus_call_ms=%.3f layout_ms=%.3f native_reason=%s",
            backend, id,
            navigation.focus_event_at and
                ((navigation.focus_event_at - navigation.requested_at) / 1000000) or 0,
            navigation.focus_call_ms or 0,
            navigation.focus_event_at and
                ((navigation.layout_complete_at - navigation.focus_event_at) / 1000000) or 0,
            tostring(native_transform_error))
    end
end

local function finishInteractiveMove(set_real_positions)
    if not interactive_moves then return end

    local records = {}
    for _, id in ipairs(interactive_move_order or {}) do
        local record = interactive_moves[id]
        if record then table.insert(records, record) end
    end
    if #records == 0 then
        for _, record in pairs(interactive_moves) do table.insert(records, record) end
    end

    local committed, commit_error = true, nil
    local position_errors = {}
    if interactive_move_display_link then
        local moves = {}
        for _, record in ipairs(records) do
            table.insert(moves, {
                id = record.id,
                x = record.end_frame.x,
                y = record.end_frame.y,
            })
        end
        committed, commit_error = nativeHelperCall("interactiveEnd", moves)
        if not committed and set_real_positions then
            committed, commit_error = nativeHelperCall("move", moves)
        end
        if not committed and set_real_positions then
            for _, record in ipairs(records) do
                local positioned, result = pcall(
                    record.window.setTopLeft, record.window,
                    record.end_frame.x, record.end_frame.y)
                if not positioned or result == false then
                    position_errors[record.id] = result
                end
            end
            committed = not next(position_errors)
        end
    elseif set_real_positions and not interactive_move_direct then
        committed, commit_error = commitNativePositions(records)
        if not committed then
            for _, record in ipairs(records) do
                local positioned, result = pcall(
                    record.window.setTopLeft, record.window,
                    record.end_frame.x, record.end_frame.y)
                if not positioned or result == false then
                    position_errors[record.id] = result
                end
            end
            local reset_ok, reset_error =
                nativeSet(identityTransforms(records))
            committed = reset_ok and not next(position_errors)
            commit_error = commit_error or reset_error
        end
    elseif not interactive_move_direct then
        committed, commit_error =
            nativeSet(identityTransforms(records))
    end
    interactive_moves = nil
    interactive_move_order = nil
    interactive_move_direct = false
    interactive_move_display_link = false

    if set_real_positions and not committed then
        for _, record in ipairs(records) do
            local position_error = position_errors[record.id]
            abandonNativeRecord(record, position_error or commit_error)
        end
    end

    if interactive_profile and interactive_profile.samples > 0 then
        interactive_profile.average_input_age_ms =
            interactive_profile.total_input_age_ms / interactive_profile.samples
        interactive_profile.average_skylight_ms =
            interactive_profile.total_skylight_ms / interactive_profile.samples
        last_interactive_profile = interactive_profile
        if Windows.PaperWM then
            Windows.PaperWM.logger.df(
                "interactive latency: backend %s, setup %.2f ms (%d windows; pre-begin %.2f, native check %.2f, cleanup %.2f, bounds %.2f, fallback AX %.2f), input %.2f ms avg/%.2f max, native IPC %.2f ms avg/%.2f max",
                tostring(interactive_profile.backend),
                interactive_profile.gesture_setup_ms or 0,
                interactive_profile.window_count or 0,
                interactive_profile.pre_begin_ms or 0,
                interactive_profile.native_check_ms or 0,
                interactive_profile.cleanup_ms or 0,
                interactive_profile.bounds_ms or 0,
                interactive_profile.fallback_ax_ms or 0,
                interactive_profile.average_input_age_ms,
                interactive_profile.max_input_age_ms,
                interactive_profile.average_skylight_ms,
                interactive_profile.max_skylight_ms)
        end
        traceNativeAnimation(
            "interactive status=complete backend=%s windows=%d samples=%d setup_ms=%.3f input_avg_ms=%.3f input_max_ms=%.3f native_avg_ms=%.3f native_max_ms=%.3f display_link_error=%s",
            tostring(interactive_profile.backend),
            interactive_profile.window_count or 0,
            interactive_profile.samples or 0,
            interactive_profile.gesture_setup_ms or 0,
            interactive_profile.average_input_age_ms,
            interactive_profile.max_input_age_ms,
            interactive_profile.average_skylight_ms,
            interactive_profile.max_skylight_ms,
            tostring(interactive_profile.display_link_error))
    end
    interactive_profile = nil

    if not committed and Windows.PaperWM then
        Windows.PaperWM.logger.ef(
            "could not commit interactive native move: %s",
            tostring(next(position_errors) and "Accessibility position failed" or
                commit_error))
    end
end

local function clearQuarantinedWindows()
    local records = {}
    for _, record in pairs(quarantined_windows) do table.insert(records, record) end
    if #records > 0 then nativeSet(identityTransforms(records)) end
    for id, record in pairs(quarantined_windows) do
        quarantined_windows[id] = nil
        restartWatcherAfter(watcher_restart_padding, id,
            record.watcher, record.generation)
    end
end

_G.PaperWMNativeAnimationCleanup = function()
    focus_guard_generation = focus_guard_generation + 1
    focus_guard_target = nil
    if focus_guard_timer then
        focus_guard_timer:stop()
        focus_guard_timer = nil
    end
    stopAllNativeAnimations(true)
    finishInteractiveMove(true)
    clearQuarantinedWindows()
end

---@enum Direction
local Direction <const> = {
    LEFT = -1,
    RIGHT = 1,
    UP = -2,
    DOWN = 2,
    NEXT = 3,
    PREVIOUS = -3,
    WIDTH = 4,
    HEIGHT = 5,
    ASCENDING = 6,
    DESCENDING = 7,
}
Windows.Direction = Direction

---initialize module with reference to PaperWM
---@param paperwm PaperWM
function Windows.init(paperwm)
    Windows.PaperWM = paperwm
    native_transform_error = nil
    native_move_error = nil
    resetNativeBackendSelection()
end

---sample the currently configured animation timing curve
---@param progress number value from 0 to 1
---@return number
function Windows.sampleAnimationCurve(progress)
    return easeProgress(math.max(0, math.min(1, progress)))
end

---return the first window that's completely on the screen
---@param space Space space to lookup windows
---@param screen_frame Frame the coordinates of the screen
---@pram direction Direction|nil either LEFT or RIGHT
---@return Window|nil
function Windows.getFirstVisibleWindow(space, screen_frame, direction)
    direction = direction or Direction.LEFT
    local distance = math.huge
    local closest = nil

    for _, windows in ipairs(Windows.PaperWM.state.window_list[space] or {}) do
        local window = windows[1] -- take first window in column
        local d = (function()
            if direction == Direction.LEFT then
                return Windows.getWindowFrame(window).x - screen_frame.x
            elseif direction == Direction.RIGHT then
                return screen_frame.x2 - Windows.getWindowFrame(window).x2
            end
        end)() or math.huge
        if d >= 0 and d < distance then
            distance = d
            closest = window
        end
    end
    return closest
end

---return the destination frame while a lightweight position animation is active
---@param window Window
---@return Frame
function Windows.getWindowFrame(window)
    local id = window:id()
    local animation = native_animations[id] or position_animations[id] or
        (interactive_moves and interactive_moves[id]) or quarantined_windows[id]
    local native_bounds_enabled = nativeBoundsBackendEnabled()
    local frame = animation and animation.end_frame or
        (native_bounds_enabled and nativeBounds(id)) or window:frame()
    return hs.geometry.rect(frame.x, frame.y, frame.w, frame.h)
end

---report whether the experimental native animation helper can be used
---@return boolean
---@return string|nil
function Windows.nativeAnimationStatus()
    local selection = selectNativeBackends()
    if selection.transform then return true, nil end
    return false, native_transform_error or selection.reason
end

---report whether native direct movement can be used for interactive gestures
---@return boolean
---@return string|nil
function Windows.nativeInteractiveStatus()
    local selection = selectNativeBackends()
    if nativeMoveBackendEnabled() then return true, nil end
    return false, native_move_error or native_helper_error or selection.reason
end

---report the cached native write-capability decision
---@return table
function Windows.nativeBackendStatus()
    local selection = selectNativeBackends()
    local status = {}
    for key, value in pairs(selection) do status[key] = value end
    status.transform_reason = native_transform_error
    status.move_reason = native_move_error
    return status
end

---diagnose private transform entry points for managed windows
---@param ids number[]|nil
---@return table|nil
---@return string|nil
function Windows.nativeProbe(ids)
    local helper = loadNativeHelper()
    if not helper or type(helper.probe) ~= "function" then
        return nil, native_helper_error or
            "native helper was built without probe support"
    end

    if not ids then
        ids = {}
        for id in pairs(Windows.PaperWM.state.index_table) do
            table.insert(ids, id)
        end
        table.sort(ids)
    end

    local called, result = pcall(helper.probe, ids)
    if not called then return nil, result end
    return result, nil
end

---perform one immediate trackpad haptic tick
---@return boolean
---@return string|nil
function Windows.performHapticFeedback()
    local helper = loadNativeHaptic()
    if not helper then return false, native_haptic_error end

    local called, result, reason = pcall(helper.haptic)
    if called and result then return true, nil end

    native_haptic = nil
    native_haptic_checked = true
    native_haptic_error = called and reason or result
    return false, native_haptic_error
end

---start passive HID++ gesture-button and RawXY observation
---@param feature_index number
---@param cid number
---@return boolean
---@return string|nil
function Windows.startHIDPPGestureMonitor(feature_index, cid)
    local helper = loadNativeHelper()
    if not helper or type(helper.hidppMonitorStart) ~= "function" then
        return false, native_helper_error or
            "native helper was built without HID++ monitor support"
    end

    local called, started, reason = pcall(
        helper.hidppMonitorStart, feature_index, cid)
    if not called then return false, started end
    return started == true, reason
end

---return and clear HID++ RawXY accumulated since the previous poll
---@return table|nil
---@return string|nil
function Windows.pollHIDPPGesture()
    local helper = loadNativeHelper()
    if not helper or type(helper.hidppMonitorPoll) ~= "function" then
        return nil, native_helper_error or
            "native helper was built without HID++ monitor support"
    end

    local called, sample, reason = pcall(helper.hidppMonitorPoll)
    if not called then return nil, sample end
    return sample, reason
end

---stop passive HID++ observation
function Windows.stopHIDPPGestureMonitor()
    local helper = loadNativeHelper()
    if helper and type(helper.hidppMonitorStop) == "function" then
        pcall(helper.hidppMonitorStop)
    end
end

---return timing from the most recently completed compositor gesture
---@return table|nil
function Windows.interactiveLatencyStatus()
    return last_interactive_profile
end

---return timing from the most recently completed native layout animation
---@return table|nil
function Windows.nativeAnimationLatencyStatus()
    return last_native_animation_profile
end

---begin a compositor-backed interactive position gesture
---@param items table[] tables containing a window and optional current frame
---@param gesture_started number|nil absolute time before gesture setup began
---@return boolean
---@return boolean swipe_blocked
function Windows.beginInteractiveMove(items, gesture_started)
    local begin_started = Timer.absoluteTime()
    gesture_started = gesture_started or begin_started

    local native_check_started = Timer.absoluteTime()
    local preferred = {}
    for _, item in ipairs(items) do table.insert(preferred, item.window:id()) end
    local native_enabled = nativeMoveBackendEnabled(preferred)
    local native_check_ms = (Timer.absoluteTime() - native_check_started) / 1000000
    if not native_enabled then
        traceNativeAnimation(
            "interactive status=unavailable move_error=%s helper_error=%s",
            tostring(native_move_error), tostring(native_helper_error))
        local frames = nativeBoundsBackendEnabled() and
            nativeBoundsBatch(items) or {}
        for _, item in ipairs(items) do
            if not item.frame then
                item.frame = frames[item.window:id()] or item.window:frame()
            end
        end
        return false, false
    end

    if interactive_moves then
        local record_count = 0
        for _ in pairs(interactive_moves) do record_count = record_count + 1 end
        local can_resume = record_count == #items
        for _, item in ipairs(items) do
            if not interactive_moves[item.window:id()] then
                can_resume = false
                break
            end
        end

        if can_resume then
            for _, item in ipairs(items) do
                local record = interactive_moves[item.window:id()]
                -- item.x comes from x_positions and is the authoritative
                -- virtual canvas coordinate. A distant window's retained
                -- WindowServer frame may be parked at the screen edge, so
                -- copying record.end_frame.x back into item.x can collapse
                -- several off-canvas columns onto the same edge position.
                item.frame = hs.geometry.rect(
                    item.x, record.end_frame.y,
                    record.end_frame.w, record.end_frame.h)
                record.end_frame.x = item.x
            end
            if interactive_profile then
                interactive_profile.resume_count =
                    (interactive_profile.resume_count or 0) + 1
            end
            return true, false
        end
    end

    local cleanup_started = Timer.absoluteTime()
    finishInteractiveMove(true)
    stopAllPositionAnimations(true)
    local adopted_frames, adopted_real_frames, adoption_blocked =
        adoptNativeAnimationFrames(items)
    if adoption_blocked then return false, true end
    if not adopted_frames then stopAllNativeAnimations(true) end
    local cleanup_ms = (Timer.absoluteTime() - cleanup_started) / 1000000

    local bounds_started = Timer.absoluteTime()
    local frames = nativeBoundsBatch(items)
    local bounds_ms = (Timer.absoluteTime() - bounds_started) / 1000000

    interactive_moves = {}
    interactive_move_order = {}
    interactive_move_direct = true
    interactive_move_display_link = false
    interactive_profile = {
        window_count = #items,
        pre_begin_ms = (begin_started - gesture_started) / 1000000,
        native_check_ms = native_check_ms,
        cleanup_ms = cleanup_ms,
        bounds_ms = bounds_ms,
        fallback_ax_ms = 0,
        samples = 0,
        total_input_age_ms = 0,
        max_input_age_ms = 0,
        total_skylight_ms = 0,
        max_skylight_ms = 0,
    }

    for _, item in ipairs(items) do
        local id = item.window:id()
        table.insert(interactive_move_order, id)
        -- Invalidate any delayed watcher restart left by an interrupted
        -- animation; the gesture owner restarts its watchers when it ends.
        move_generations[id] = (move_generations[id] or 0) + 1
        local adopted_frame = adopted_frames and adopted_frames[id]
        local frame = adopted_frame or frames[id] or item.frame
        if not frame then
            local fallback_started = Timer.absoluteTime()
            frame = item.window:frame()
            interactive_profile.fallback_ax_ms = interactive_profile.fallback_ax_ms +
                ((Timer.absoluteTime() - fallback_started) / 1000000)
        end
        local real_frame = (adopted_real_frames and adopted_real_frames[id]) or frame
        if adopted_frame then item.x = adopted_frame.x end
        item.frame = hs.geometry.rect(frame.x, frame.y, frame.w, frame.h)
        interactive_moves[id] = {
            id = id,
            window = item.window,
            watcher = Windows.PaperWM.state.ui_watchers[id],
            generation = move_generations[id],
            real_frame = real_frame,
            end_frame = hs.geometry.rect(frame.x, frame.y, frame.w, frame.h),
        }
    end
    if nativeInteractiveDisplayLinkEnabled() then
        local initial_moves = {}
        for _, id in ipairs(interactive_move_order) do
            local record = interactive_moves[id]
            table.insert(initial_moves, {
                id = id,
                x = record.end_frame.x,
                y = record.end_frame.y,
            })
        end
        local started, reason = nativeHelperCall(
            "interactiveBegin", initial_moves)
        interactive_move_display_link = started
        if not started then
            interactive_profile.display_link_error = reason
            traceNativeAnimation(
                "interactive display-link unavailable reason=%s",
                tostring(reason))
        end
    end
    interactive_profile.backend = interactive_move_display_link and
        "dockDisplayLink" or "synchronousMove"
    interactive_profile.gesture_setup_ms =
        (Timer.absoluteTime() - gesture_started) / 1000000
    return true, false
end

---apply compositor window positions during an interactive gesture
---@param items table[] tables containing a window and desired frame
---@param input_timestamp number|nil event timestamp in absolute nanoseconds
---@return boolean
---@return string|nil
function Windows.updateInteractiveMove(items, input_timestamp)
    if not interactive_moves then
        return false, "no interactive compositor move is active"
    end

    local moves = {}
    for _, item in ipairs(items) do
        local record = interactive_moves[item.window:id()]
        if record then
            record.end_frame.x = item.frame.x
            record.end_frame.y = item.frame.y
        end
    end
    for _, id in ipairs(interactive_move_order or {}) do
        local record = interactive_moves[id]
        if record then
            table.insert(moves, {
                id = record.id,
                x = record.end_frame.x,
                y = record.end_frame.y,
            })
        end
    end

    local call_started = Timer.absoluteTime()
    local input_age_ms = input_timestamp and input_timestamp > 0 and
        math.max(0, (call_started - input_timestamp) / 1000000) or 0
    local method = interactive_move_display_link and
        "interactiveUpdate" or "move"
    local transformed, reason = nativeHelperCall(method, moves)
    if not transformed and interactive_move_display_link then
        -- Stop a stale display-link owner before reverting to the legacy
        -- synchronous route, otherwise its last buffered frame can overwrite
        -- a later move.
        nativeHelperCall("interactiveEnd", moves)
        interactive_move_display_link = false
        if interactive_profile then
            interactive_profile.backend = "synchronousMoveFallback"
            interactive_profile.display_link_error = reason
        end
        transformed, reason = nativeHelperCall("move", moves)
    end
    local skylight_ms = (Timer.absoluteTime() - call_started) / 1000000
    if interactive_profile then
        interactive_profile.samples = interactive_profile.samples + 1
        interactive_profile.total_input_age_ms =
            interactive_profile.total_input_age_ms + input_age_ms
        interactive_profile.max_input_age_ms =
            math.max(interactive_profile.max_input_age_ms, input_age_ms)
        interactive_profile.total_skylight_ms =
            interactive_profile.total_skylight_ms + skylight_ms
        interactive_profile.max_skylight_ms =
            math.max(interactive_profile.max_skylight_ms, skylight_ms)
    end
    if transformed then return true, nil end

    native_move_error = reason
    traceNativeAnimation("interactive status=failed reason=%s", tostring(reason))
    finishInteractiveMove(true)
    Windows.PaperWM.logger.ef(
        "interactive native move failed; falling back to Accessibility: %s", reason)
    return false, reason
end

---commit and clear an interactive compositor gesture
function Windows.endInteractiveMove()
    finishInteractiveMove(true)
end

---get a column of windows for a space from the window_list
---@param space Space
---@param col number
---@return Window[]
function Windows.getColumn(space, col) return (Windows.PaperWM.state.window_list[space] or {})[col] end

---get a window in a row, in a column, in a space from the window_list
---@param space Space
---@param col number
---@param row number
---@return Window
function Windows.getWindow(space, col, row)
    return (Windows.getColumn(space, col) or {})[row]
end

---get the gap value for the specified side
---@param side string "top", "bottom", "left", or "right"
---@return number gap size in pixels
function Windows.getGap(side)
    local gap = Windows.PaperWM.window_gap
    if type(gap) == "number" then
        return gap            -- backward compatibility with single number
    elseif type(gap) == "table" then
        return gap[side] or 8 -- default to 8 if missing
    else
        return 8              -- fallback default
    end
end

---get the tileable bounds for a screen
---@param screen Screen
---@return Frame
function Windows.getCanvas(screen)
    local screen_frame = screen:frame()
    local left_gap = Windows.getGap("left")
    local right_gap = Windows.getGap("right")
    local top_gap = Windows.getGap("top")
    local bottom_gap = Windows.getGap("bottom")

    return hs.geometry.rect(
        screen_frame.x + left_gap,
        screen_frame.y + top_gap,
        screen_frame.w - (left_gap + right_gap),
        screen_frame.h - (top_gap + bottom_gap)
    )
end

---update the column number in window_list to be ascending from provided column up
---@param space Space
---@param column number
function Windows.updateIndexTable(space, column)
    local columns = Windows.PaperWM.state.window_list[space] or {}
    for col = column, #columns do
        for row, window in ipairs(Windows.getColumn(space, col)) do
            Windows.PaperWM.state.index_table[window:id()] = { space = space, col = col, row = row }
        end
    end
end

---update the virtual x position for a table of windows on the specified space
---@param space Space
---@param windows Window[]
function Windows.updateVirtualPositions(space, windows, x)
    if not Windows.PaperWM.state.x_positions[space] then
        Windows.PaperWM.state.x_positions[space] = {}
    end
    local updated = false
    for _, window in ipairs(windows) do
        Windows.PaperWM.state.x_positions[space][window:id()] = x
    end
    return updated
end

---save the is_floating list to settings
function Windows.persistFloatingList()
    local persisted = {}
    for k, _ in pairs(Windows.PaperWM.state.is_floating) do
        table.insert(persisted, k)
    end
    hs.settings.set(Windows.PaperWM.state.IsFloatingKey, persisted)
end

---tile a column of window by moving and resizing
---@param windows Window[] column of windows
---@param bounds Frame bounds to constrain column of tiled windows
---@param h number|nil set windows to specified height
---@param w number|nil set windows to specified width
---@param id number|nil id of window to set specific height
---@param h4id number|nil specific height for provided window id
---@return number width of tiled column
function Windows.tileColumn(windows, bounds, h, w, id, h4id)
    local last_window, frame
    local bottom_gap = Windows.getGap("bottom")

    for _, window in ipairs(windows) do
        frame = Windows.getWindowFrame(window)
        w = w or frame.w -- take given width or width of first window
        if bounds.x then -- set either left or right x coord
            frame.x = bounds.x
        elseif bounds.x2 then
            frame.x = bounds.x2 - w
        end
        if h then              -- set height if given
            if id and h4id and window:id() == id then
                frame.h = h4id -- use this height for window with id
            else
                frame.h = h    -- use this height for all other windows
            end
        end
        frame.y = bounds.y
        frame.w = w
        frame.y2 = math.min(frame.y2, bounds.y2) -- don't overflow bottom of bounds
        Windows.moveWindow(window, frame)
        bounds.y = math.min(frame.y2 + bottom_gap, bounds.y2)
        last_window = window
    end

    -- expand last window height to bottom
    if frame.y2 ~= bounds.y2 then
        frame.y2 = bounds.y2
        Windows.moveWindow(last_window, frame)
    end
    return w -- return width of column
end

---get all windows across all spaces and retile them
function Windows.refreshWindows()
    -- get all windows across spaces
    local all_windows = Windows.PaperWM.window_filter:getWindows()

    local retile_spaces = {} -- spaces that need to be retiled
    for _, window in ipairs(all_windows) do
        local index = Windows.PaperWM.state.index_table[window:id()]
        if Windows.PaperWM.state.is_floating[window:id()] then
            -- ignore floating windows
        elseif not index then
            -- add window
            local space = Windows.addWindow(window)
            if space then retile_spaces[space] = true end
        elseif index.space ~= Spaces.windowSpaces(window)[1] then
            -- move to window list in new space, don't focus nearby window
            Windows.removeWindow(window, true)
            local space = Windows.addWindow(window)
            if space then retile_spaces[space] = true end
        end
    end

    -- retile spaces
    for space, _ in pairs(retile_spaces) do Windows.PaperWM:tileSpace(space) end
end

---add a new window to be tracked and automatically tiled
---@param add_window Window new window to be added
---@return Space|nil space that contains new window
function Windows.addWindow(add_window)
    -- A window with no tabs will have a tabCount of 0
    -- A new tab for a window will have tabCount equal to the total number of tabs
    -- All existing tabs in a window will have their tabCount reset to 0
    -- We can't query whether an exiting hs.window is a tab or not after creation
    local apple <const> = "com.apple"
    if add_window:tabCount() > 0 and add_window:application():bundleID():sub(1, #apple) == apple then
        -- It's mostly built-in Apple apps like Finder and Terminal whose tabs
        -- show up as separate windows. Third party apps like Microsoft Office
        -- use tabs that are all contained within one window and tile fine.
        hs.notify.show("PaperWM", "Windows with tabs are not supported!",
            "See https://github.com/mogenson/PaperWM.spoon/issues/39")
        return
    end

    -- ignore windows that have a zoom button, but are not maximizable
    -- if not add_window:isMaximizable() then
    --     Windows.PaperWM.logger.d("ignoring non-maximizable window")
    --     return
    -- end
    -- local f = add_window:frame()
    -- if f.w < 300 and f.h < 300 then
    --     Windows.PaperWM.logger.d("ignoring small window")
    --     return
    -- end
    

    -- check if window is already in window list
    local existing_index = Windows.PaperWM.state.index_table[add_window:id()]
    if existing_index then return existing_index.space end

    local space = Spaces.windowSpaces(add_window)[1]
    if not space then
        Windows.PaperWM.logger.df("window %d does not have a Space yet", add_window:id())
        return
    end
    if not Windows.PaperWM.state.window_list[space] then Windows.PaperWM.state.window_list[space] = {} end

    -- find where to insert window
    local add_column = 1

    -- when addWindow() is called from a window created event:
    -- focused_window from previous window focused event will not be add_window
    -- hs.window.focusedWindow() will return add_window
    -- new window focused event for add_window has not happened yet
    if Windows.PaperWM.state.prev_focused_window and
        ((Windows.PaperWM.state.index_table[Windows.PaperWM.state.prev_focused_window:id()] or {}).space == space) and
        (Windows.PaperWM.state.prev_focused_window:id() ~= add_window:id()) then
        add_column = Windows.PaperWM.state.index_table[Windows.PaperWM.state.prev_focused_window:id()].col +
            1 -- insert to the right
    else
        local x = Windows.getWindowFrame(add_window).center.x
        for col, windows in ipairs(Windows.PaperWM.state.window_list[space]) do
            if x < Windows.getWindowFrame(windows[1]).center.x then
                add_column = col     -- insert left of window
                break                -- add_window will take this window's column
            else                     -- everything after insert column will be pushed right
                add_column = col + 1 -- insert right of window
            end
        end
    end

    -- add window
    clipped_add_column = math.min(#Windows.PaperWM.state.window_list[space] + 1, add_column)
    table.insert(Windows.PaperWM.state.window_list[space], clipped_add_column, { add_window })

    -- update index table
    Windows.updateIndexTable(space, clipped_add_column)

    -- subscribe to window moved events
    local watcher = add_window:newWatcher(
        function(window, event, _, self)
            Windows.PaperWM.events.windowEventHandler(window, event, self)
        end, Windows.PaperWM)
    watcher:start({ Watcher.windowMoved, Watcher.windowResized })
    Windows.PaperWM.state.ui_watchers[add_window:id()] = watcher

    return space
end

---remove a window from being tracked and automatically tiled
---@param remove_window Window window to be removed
---@param skip_new_window_focus boolean|nil don't focus a nearby window if true
---@return Space|nil space that contained removed window
function Windows.removeWindow(remove_window, skip_new_window_focus)
    -- get index of window
    local remove_index = Windows.PaperWM.state.index_table[remove_window:id()]
    if not remove_index then
        Windows.PaperWM.logger.df("ignoring removal of untracked window %d", remove_window:id())
        return
    end

    if not skip_new_window_focus then -- find nearby window to focus
        for _, direction in ipairs({
            Direction.DOWN, Direction.UP, Direction.LEFT, Direction.RIGHT,
        }) do if Windows.focusWindow(direction, remove_index) then break end end
    end

    -- remove window
    table.remove(Windows.PaperWM.state.window_list[remove_index.space][remove_index.col],
        remove_index.row)
    if #Windows.PaperWM.state.window_list[remove_index.space][remove_index.col] == 0 then
        table.remove(Windows.PaperWM.state.window_list[remove_index.space], remove_index.col)
    end

    -- remove watcher
    Windows.PaperWM.state.ui_watchers[remove_window:id()]:stop()
    Windows.PaperWM.state.ui_watchers[remove_window:id()] = nil

    -- clear window position
    -- local xposs = Windows.PaperWM.state.x_positions
    -- if xposs[remove_index.space] and xposs[remove_index.space][remove_window] then
    --     xposs[remove_index.space][remove_window] = nil
    -- else
    --     print("well shit")
    -- end
    (Windows.PaperWM.state.x_positions[remove_index.space] or {})[remove_window:id()] = nil

    -- update index table
    Windows.PaperWM.state.index_table[remove_window:id()] = nil
    Windows.updateIndexTable(remove_index.space, remove_index.col)

    -- remove if space is empty
    if #Windows.PaperWM.state.window_list[remove_index.space] == 0 then
        Windows.PaperWM.state.window_list[remove_index.space] = nil
        Windows.PaperWM.state.x_positions[remove_index.space] = nil
    end

    return remove_index.space -- return space for removed window
end

function Windows.removeWindowIndex(remove_index, remove_id)
    -- remove window
    table.remove(Windows.PaperWM.state.window_list[remove_index.space][remove_index.col],
        remove_index.row)
    if #Windows.PaperWM.state.window_list[remove_index.space][remove_index.col] == 0 then
        table.remove(Windows.PaperWM.state.window_list[remove_index.space], remove_index.col)
    end

    -- remove watcher
    Windows.PaperWM.state.ui_watchers[remove_id]:stop()
    Windows.PaperWM.state.ui_watchers[remove_id] = nil

    -- clear window position
    hs.printf("trying to remove id %d\n", remove_id)

    local xposs = Windows.PaperWM.state.x_positions
    if xposs[remove_index.space] and xposs[remove_index.space][remove_window] then
        xposs[remove_index.space][remove_window] = nil
    else
        for i, xpos in pairs(xposs) do
            for w, _ in pairs(xpos) do
                if w == remove_id then
                    print("Removed")
                    xpos[w] = nil
                end
            end
        end
    end

    -- update index table
    Windows.PaperWM.state.index_table[remove_id] = nil
    Windows.updateIndexTable(remove_index.space, remove_index.col)

    -- remove if space is empty
    if #Windows.PaperWM.state.window_list[remove_index.space] == 0 then
        Windows.PaperWM.state.window_list[remove_index.space] = nil
        Windows.PaperWM.state.x_positions[remove_index.space] = nil
    end

    return remove_index.space -- return space for removed window
end

local function beginFocusGuard(window)
    focus_guard_generation = focus_guard_generation + 1
    local generation = focus_guard_generation
    focus_guard_target = window
    if focus_guard_timer then focus_guard_timer:stop() end

    focus_guard_timer = Timer.doAfter(
        math.max(0, Window.animationDuration) + watcher_restart_padding,
        function()
            if generation ~= focus_guard_generation then return end
            local target = focus_guard_target
            focus_guard_target = nil
            focus_guard_timer = nil
            if target and Window.focusedWindow() ~= target then
                pcall(target.focus, target)
            end
        end)
    pcall(window.focus, window)
end

---redirect transient focus changes while a keyboard transition owns focus
---@param window Window
---@return boolean
function Windows.redirectTransientFocus(window)
    local target = focus_guard_target
    if not target or window:id() == target:id() then return false end
    local redirected = pcall(target.focus, target)
    return redirected
end

---move focus to a new window next to the currently focused window
---@param direction Direction use either Direction UP, DOWN, LEFT, or RIGHT
---@param focused_index Index index of focused window within the window_list
function Windows.focusWindow(direction, focused_index)
    local navigation_started = Timer.absoluteTime()
    if not focused_index then
        -- get current focused window
        local focused_window = focus_guard_target or Window.focusedWindow()
        if not focused_window then
            Windows.PaperWM.logger.d("focused window not found")
            return
        end

        -- get focused window index
        focused_index = Windows.PaperWM.state.index_table[focused_window:id()]
    end

    if not focused_index then
        Windows.PaperWM.logger.e("focused index not found")
        return
    end

    -- get new focused window
    local new_focused_window = nil
    if direction == Direction.LEFT or direction == Direction.RIGHT then
        -- walk down column, looking for match in neighbor column
        for row = focused_index.row, 1, -1 do
            new_focused_window = Windows.getWindow(focused_index.space,
                focused_index.col + direction, row)
            if new_focused_window then break end
        end
    elseif direction == Direction.UP or direction == Direction.DOWN then
        new_focused_window = Windows.getWindow(focused_index.space, focused_index.col,
            focused_index.row + (direction // 2))
    elseif direction == Direction.NEXT or direction == Direction.PREVIOUS then
        local diff = direction // Direction.NEXT -- convert to 1/-1
        local focused_column = Windows.getColumn(focused_index.space, focused_index.col)
        local new_row_index = focused_index.row + diff

        -- first try above/below in same row
        new_focused_window = Windows.getWindow(focused_index.space, focused_index.col, focused_index.row + diff)

        if not new_focused_window then
            -- get the bottom row in the previous column, or the first row in the next column
            local adjacent_column = Windows.getColumn(focused_index.space, focused_index.col + diff)
            if adjacent_column then
                local col_idx = 1
                if diff < 0 then col_idx = #adjacent_column end
                new_focused_window = adjacent_column[col_idx]
            end
        end
    end

    if not new_focused_window then
        Windows.PaperWM.logger.d("new focused window not found")
        return
    end

    -- Keep the destination focused for the complete layout transition.
    local navigation = {
        requested_at = navigation_started,
        target = new_focused_window:id(),
        space = focused_index.space,
    }
    pending_keyboard_navigation = navigation
    local focus_started = Timer.absoluteTime()
    beginFocusGuard(new_focused_window)
    navigation.focus_call_ms =
        (Timer.absoluteTime() - focus_started) / 1000000

    return new_focused_window
end

---focus a window at a specified position
---@param new_index number the index from left to right on the current screen
function Windows.focusWindowAt(new_index)
    local screen = Screen.mainScreen()
    local space = Spaces.activeSpaces()[screen:getUUID()]
    local columns = Windows.PaperWM.state.window_list[space]
    if not columns then return end

    local index = 1
    for col_idx = 1, #columns do
        column = columns[col_idx]
        for row_idx = 1, #column do
            if index == new_index then
                column[row_idx]:focus()
                return
            end
            index = index + 1
        end
    end
end

---focus a window at a specified position
---@param new_index number the index from left to right on the current screen
function Windows.focusWindowID(id)
    local screen = Screen.mainScreen()
    local space = Spaces.activeSpaces()[screen:getUUID()]
    local index = Windows.PaperWM.state.index_table[id]
    Windows.PaperWM.state.window_list[space][index["col"]][index["row"]]:focus()
end

---swap the focused window with a window next to it
---if swapping horizontally and the adjacent window is in a column, swap the
---entire column. if swapping vertically and the focused window is in a column,
---swap positions within the column
---@param direction Direction use Direction LEFT, RIGHT, UP, or DOWN
function Windows.swapWindows(direction)
    -- use focused window as source window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.PaperWM.logger.d("focused window not found")
        return
    end

    -- get focused window index
    local focused_index = Windows.PaperWM.state.index_table[focused_window:id()]
    if not focused_index then
        Windows.PaperWM.logger.e("focused index not found")
        return
    end

    if direction == Direction.LEFT or direction == Direction.RIGHT then
        -- get target windows
        local target_index = { col = focused_index.col + direction }
        local target_column = Windows.getColumn(focused_index.space, target_index.col)
        if not target_column then
            Windows.PaperWM.logger.d("target column not found")
            return
        end

        -- swap place in window list
        local focused_column = Windows.getColumn(focused_index.space, focused_index.col)
        Windows.PaperWM.state.window_list[focused_index.space][target_index.col] = focused_column
        Windows.PaperWM.state.window_list[focused_index.space][focused_index.col] = target_column

        -- update index table
        for row, window in ipairs(target_column) do
            Windows.PaperWM.state.index_table[window:id()] = {
                space = focused_index.space,
                col = focused_index.col,
                row = row,
            }
        end
        for row, window in ipairs(focused_column) do
            Windows.PaperWM.state.index_table[window:id()] = {
                space = focused_index.space,
                col = target_index.col,
                row = row,
            }
        end

        -- swap frames
        local focused_frame = Windows.getWindowFrame(focused_window)
        local target_frame = Windows.getWindowFrame(target_column[1])
        local right_gap = Windows.getGap("right")
        local left_gap = Windows.getGap("left")
        if direction == Direction.LEFT then
            focused_frame.x = target_frame.x
            target_frame.x = focused_frame.x2 + right_gap
        else -- Direction.RIGHT
            target_frame.x = focused_frame.x
            focused_frame.x = target_frame.x2 + right_gap
        end
        for _, window in ipairs(target_column) do
            local frame = Windows.getWindowFrame(window)
            frame.x = target_frame.x
            Windows.moveWindow(window, frame)
        end
        for _, window in ipairs(focused_column) do
            local frame = Windows.getWindowFrame(window)
            frame.x = focused_frame.x
            Windows.moveWindow(window, frame)
        end
    elseif direction == Direction.UP or direction == Direction.DOWN then
        -- get target window
        local target_index = {
            space = focused_index.space,
            col = focused_index.col,
            row = focused_index.row + (direction // 2),
        }
        local target_window = Windows.getWindow(target_index.space, target_index.col,
            target_index.row)
        if not target_window then
            Windows.PaperWM.logger.d("target window not found")
            return
        end

        -- swap places in window list
        Windows.PaperWM.state.window_list[target_index.space][target_index.col][target_index.row] =
            focused_window
        Windows.PaperWM.state.window_list[focused_index.space][focused_index.col][focused_index.row] =
            target_window

        -- update index table
        Windows.PaperWM.state.index_table[target_window:id()] = focused_index
        Windows.PaperWM.state.index_table[focused_window:id()] = target_index

        -- swap frames
        local focused_frame = Windows.getWindowFrame(focused_window)
        local target_frame = Windows.getWindowFrame(target_window)
        local bottom_gap = Windows.getGap("bottom")
        if direction == Direction.UP then
            focused_frame.y = target_frame.y
            target_frame.y = focused_frame.y2 + bottom_gap
        else -- Direction.DOWN
            target_frame.y = focused_frame.y
            focused_frame.y = target_frame.y2 + bottom_gap
        end
        Windows.moveWindow(focused_window, focused_frame)
        Windows.moveWindow(target_window, target_frame)
    end

    -- update layout
    Windows.PaperWM:tileSpace(focused_index.space)
end

---exchange two columns of windows
---@param direction Direction Direction.LEFT or Direction.RIGHT
function Windows.swapColumns(direction)
    -- use focused window as source window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.PaperWM.logger.e("focused window not found")
        return
    end

    -- get focused window index
    local focused_index = Windows.PaperWM.state.index_table[focused_window:id()]
    if not focused_index then
        Windows.PaperWM.logger.e("focused index not found")
        return
    end

    local focused_column = Windows.getColumn(focused_index.space, focused_index.col)
    if not focused_column then
        Windows.PaperWM.logger.e("focused column not found")
        return
    end

    local adjacent_column_index = focused_index.col + direction
    local adjacent_column = Windows.getColumn(focused_index.space, adjacent_column_index)
    if not adjacent_column then return end

    -- swap column in window list
    Windows.PaperWM.state.window_list[focused_index.space][adjacent_column_index] = focused_column
    Windows.PaperWM.state.window_list[focused_index.space][focused_index.col] = adjacent_column

    local focused_frame = Windows.getWindowFrame(focused_window)
    local adjacent_window = adjacent_column[1]
    if not adjacent_window then
        Windows.PaperWM.logger.e("adjacent window not found")
        return
    end

    local adjacent_frame = Windows.getWindowFrame(adjacent_window)
    local focused_x = focused_frame.x
    local adjacent_x = adjacent_frame.x

    -- update index table
    for row, window in ipairs(adjacent_column) do
        local index = Windows.PaperWM.state.index_table[window:id()]
        if index then
            Windows.PaperWM.state.index_table[window:id()]["col"] = focused_index.col
        else
            Windows.PaperWM.logger.e("index_table missing window " .. window:id())
        end
    end

    for row, window in ipairs(focused_column) do
        local index = Windows.PaperWM.state.index_table[window:id()]
        if index then
            Windows.PaperWM.state.index_table[window:id()]["col"] = adjacent_column_index
        else
            Windows.PaperWM.logger.e("index_table missing window " .. window:id())
        end
    end

    -- update window positions
    for row, window in ipairs(adjacent_column) do
        local frame = Windows.getWindowFrame(window)
        Windows.moveWindow(window, Rect(focused_x, frame.y, frame.w, frame.h))
    end

    for row, window in ipairs(focused_column) do
        local frame = Windows.getWindowFrame(window)
        Windows.moveWindow(window, Rect(adjacent_x, frame.y, frame.w, frame.h))
    end

    -- update layout
    Windows.PaperWM:tileSpace(focused_index.space)
end

---move the focused window to the center of the screen, horizontally
---don't resize the window or change it's vertical position
function Windows.centerWindow()
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.PaperWM.logger.d("focused window not found")
        return
    end

    -- get global coordinates
    local focused_frame = Windows.getWindowFrame(focused_window)
    local screen_frame = focused_window:screen():frame()

    -- center window
    focused_frame.x = screen_frame.x + (screen_frame.w // 2) -
        (focused_frame.w // 2)
    Windows.moveWindow(focused_window, focused_frame)

    -- update layout
    local space = Spaces.windowSpaces(focused_window)[1]
    Windows.PaperWM:tileSpace(space)
end

---set the focused window to the width of the screen and cache the original width
---restore the original window size if called again, don't change the height
function Windows.toggleWindowFullWidth()
    local width_cache = {}
    return function(self)
        -- get current focused window
        local focused_window = Window.focusedWindow()
        if not focused_window then
            self.logger.d("focused window not found")
            return
        end

        local canvas = Windows.getCanvas(focused_window:screen())
        local focused_frame = Windows.getWindowFrame(focused_window)
        local id = focused_window:id()

        local width = width_cache[id]
        if width then
            -- restore window width
            focused_frame.x = canvas.x + ((canvas.w - width) / 2)
            focused_frame.w = width
            width_cache[id] = nil
        else
            -- set window to fullscreen width
            width_cache[id] = focused_frame.w
            focused_frame.x, focused_frame.w = canvas.x, canvas.w
        end

        -- update layout
        Windows.moveWindow(focused_window, focused_frame)
        local space = Spaces.windowSpaces(focused_window)[1]
        Windows.PaperWM:tileSpace(space)
    end
end

---resize the width or height of the window, keeping the other dimension the
---same. cycles through the ratios specified in PaperWM.window_ratios
---@param direction Direction use Direction.WIDTH or Direction.HEIGHT
---@param cycle_direction Direction use Direction.ASCENDING or DESCENDING
function Windows.cycleWindowSize(direction, cycle_direction)
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.PaperWM.logger.d("focused window not found")
        return
    end

    local function findNewSize(area_size, frame_size, cycle_direction, dimension)
        local gap
        if dimension == Direction.WIDTH then
            -- For width, use the average of left and right gaps
            gap = (Windows.getGap("left") + Windows.getGap("right")) / 2
        else
            -- For height, use the average of top and bottom gaps
            gap = (Windows.getGap("top") + Windows.getGap("bottom")) / 2
        end

        local sizes = {}
        local new_size = nil
        if cycle_direction == Direction.ASCENDING then
            for index, ratio in ipairs(Windows.PaperWM.window_ratios) do
                sizes[index] = ratio * (area_size + gap) - gap
            end

            -- find new size
            new_size = sizes[1]
            for _, size in ipairs(sizes) do
                if size > frame_size + 10 then
                    new_size = size
                    break
                end
            end
        elseif cycle_direction == Direction.DESCENDING then
            for index, ratio in ipairs(Windows.PaperWM.window_ratios) do
                sizes[index] = ratio * (area_size + gap) - gap
            end

            -- find new size, starting from the end
            new_size = sizes[#sizes] -- Start with the largest size
            for i = #sizes, 1, -1 do
                if sizes[i] < frame_size - 10 then
                    new_size = sizes[i]
                    break
                end
            end
        else
            Windows.PaperWM.logger.e(
                "cycle_direction must be either Direction.ASCENDING or Direction.DESCENDING")
        end

        return new_size
    end

    local canvas = Windows.getCanvas(focused_window:screen())
    local focused_frame = Windows.getWindowFrame(focused_window)

    if direction == Direction.WIDTH then
        local new_width = findNewSize(canvas.w, focused_frame.w, cycle_direction, Direction.WIDTH)
        focused_frame.x = focused_frame.x + ((focused_frame.w - new_width) // 2)
        focused_frame.w = new_width
    elseif direction == Direction.HEIGHT then
        local new_height = findNewSize(canvas.h, focused_frame.h, cycle_direction, Direction.HEIGHT)
        focused_frame.y = math.max(canvas.y,
            focused_frame.y + ((focused_frame.h - new_height) // 2))
        focused_frame.h = new_height
        focused_frame.y = focused_frame.y -
            math.max(0, focused_frame.y2 - canvas.y2)
    else
        Windows.PaperWM.logger.e(
            "direction must be either Direction.WIDTH or Direction.HEIGHT")
        return
    end

    -- apply new size
    Windows.moveWindow(focused_window, focused_frame)

    -- update layout
    local space = Spaces.windowSpaces(focused_window)[1]
    Windows.PaperWM:tileSpace(space)
end

---resize the focused window in a direction by scale amount
---@param direction Direction Direction.WIDTH or Direction.HEIGHT
---@param scale number the percent to change the window size by
function Windows.increaseWindowSize(direction, scale)
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.PaperWM.logger.d("focused window not found")
        return
    end

    local canvas = Windows.getCanvas(focused_window:screen())
    local focused_frame = Windows.getWindowFrame(focused_window)

    if direction == Direction.WIDTH then
        local diff = canvas.w * 0.1 * scale
        local new_size = math.max(diff, math.min(canvas.w, focused_frame.w + diff))

        focused_frame.w = new_size
        focused_frame.x = focused_frame.x + ((focused_frame.w - new_size) // 2)
    elseif direction == Direction.HEIGHT then
        local diff = canvas.h * 0.1 * scale
        local new_size = math.max(diff, math.min(canvas.h, focused_frame.h + diff))

        focused_frame.h = new_size
        focused_frame.y = focused_frame.y -
            math.max(0, focused_frame.y2 - canvas.y2)
    end

    -- apply new size
    Windows.moveWindow(focused_window, focused_frame)

    -- update layout
    local space = Spaces.windowSpaces(focused_window)[1]
    Windows.PaperWM:tileSpace(space)
end

---take the current focused window and move it into the bottom of
---the column to the left
function Windows.slurpWindow()
    -- TODO paperwm behavior:
    -- add top window from column to the right to bottom of current column
    -- if no colum to the right and current window is only window in current column,
    -- add current window to bottom of column to the left

    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.PaperWM.logger.d("focused window not found")
        return
    end

    -- get window index
    local focused_index = Windows.PaperWM.state.index_table[focused_window:id()]
    if not focused_index then
        Windows.PaperWM.logger.e("focused index not found")
        return
    end

    -- get column to left
    local column = Windows.getColumn(focused_index.space, focused_index.col - 1)
    if not column then
        Windows.PaperWM.logger.d("column not found")
        return
    end

    -- remove window
    table.remove(Windows.PaperWM.state.window_list[focused_index.space][focused_index.col],
        focused_index.row)
    if #Windows.PaperWM.state.window_list[focused_index.space][focused_index.col] == 0 then
        table.remove(Windows.PaperWM.state.window_list[focused_index.space], focused_index.col)
    end

    -- append to end of column
    table.insert(column, focused_window)

    -- update index table
    local num_windows = #column
    Windows.PaperWM.state.index_table[focused_window:id()] = {
        space = focused_index.space,
        col = focused_index.col - 1,
        row = num_windows,
    }
    Windows.updateIndexTable(focused_index.space, focused_index.col)

    -- adjust window frames
    local canvas = Windows.getCanvas(focused_window:screen())
    local bottom_gap = Windows.getGap("bottom")
    local bounds = {
        x = Windows.getWindowFrame(column[1]).x,
        x2 = nil,
        y = canvas.y,
        y2 = canvas.y2,
    }
    local h = math.max(0, canvas.h - ((num_windows - 1) * bottom_gap)) //
        num_windows
    Windows.tileColumn(column, bounds, h)

    -- update layout
    Windows.PaperWM:tileSpace(focused_index.space)
end

---remove focused window from it's current column and place into
---a new column to the right
function Windows.barfWindow()
    -- TODO paperwm behavior:
    -- remove bottom window of current column
    -- place window into a new column to the right--

    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.PaperWM.logger.d("focused window not found")
        return
    end

    -- get window index
    local focused_index = Windows.PaperWM.state.index_table[focused_window:id()]
    if not focused_index then
        Windows.PaperWM.logger.e("focused index not found")
        return
    end

    -- get column
    local column = Windows.getColumn(focused_index.space, focused_index.col)
    if #column == 1 then
        Windows.PaperWM.logger.d("only window in column")
        return
    end

    -- remove window and insert in new column
    table.remove(column, focused_index.row)
    table.insert(Windows.PaperWM.state.window_list[focused_index.space], focused_index.col + 1,
        { focused_window })

    -- update index table
    Windows.updateIndexTable(focused_index.space, focused_index.col)

    -- adjust window frames
    local num_windows = #column
    local canvas = Windows.getCanvas(focused_window:screen())
    local focused_frame = Windows.getWindowFrame(focused_window)
    local bottom_gap = Windows.getGap("bottom")
    local right_gap = Windows.getGap("right")

    local bounds = { x = focused_frame.x, x2 = nil, y = canvas.y, y2 = canvas.y2 }
    local h = math.max(0, canvas.h - ((num_windows - 1) * bottom_gap)) //
        num_windows
    focused_frame.y = canvas.y
    focused_frame.x = focused_frame.x2 + right_gap
    focused_frame.h = canvas.h
    Windows.moveWindow(focused_window, focused_frame)
    Windows.tileColumn(column, bounds, h)

    -- update layout
    Windows.PaperWM:tileSpace(focused_index.space)
end

---move and resize a window to the coordinates specified by the frame
---disable watchers while window is moving and re-enable after
---@param window Window window to move
---@param frame Frame coordinates to set window size and location
function Windows.moveWindow(window, frame)
    local id = window:id()
    local watcher = Windows.PaperWM.state.ui_watchers[id]
    if not watcher then
        Windows.PaperWM.logger.e("window does not have ui watcher")
        return
    end

    if frame == Windows.getWindowFrame(window) then
        Windows.PaperWM.logger.v("no change in window frame")
        return
    end

    watcher:stop()

    local generation = (move_generations[id] or 0) + 1
    move_generations[id] = generation

    local preferred = { id }
    local transform_enabled = nativeBackendEnabled(preferred)
    local move_enabled = nativeMoveBackendEnabled(preferred)
    local current_frame = nativeBoundsBackendEnabled() and
        nativeBounds(id) or window:frame()
    local can_transform = current_frame.w > 0 and current_frame.h > 0

    if can_transform and Window.animationDuration > 0 and transform_enabled then
        stopPositionAnimation(id)
        animateNativeFrame(window, current_frame, frame, watcher, generation)
    elseif can_transform and sizesMatch(current_frame, frame) and
        Window.animationDuration > 0 and move_enabled then
        stopPositionAnimation(id)
        animateNativeFrame(window, current_frame, frame, watcher, generation, true)
    elseif current_frame.w == frame.w and current_frame.h == frame.h and
        Window.animationDuration > 0 then
        stopNativeAnimation(id, true)
        current_frame = window:frame()
        local app = window:application()
        local ax_app = app and hs.axuielement.applicationElement(app)
        if ax_app and ax_app.AXEnhancedUserInterface then
            ax_app.AXEnhancedUserInterface = false
        end
        animatePosition(window, current_frame, frame, watcher, generation)
    else
        stopNativeAnimation(id, true)
        stopPositionAnimation(id)
        local app = window:application()
        local ax_app = app and hs.axuielement.applicationElement(app)
        if ax_app and ax_app.AXEnhancedUserInterface then
            ax_app.AXEnhancedUserInterface = false
        end
        window:setFrame(frame)
        restartWatcherAfter(Window.animationDuration + watcher_restart_padding,
            id, watcher, generation)
    end
end

---finish active presentation transforms and restore real window frames
function Windows.stopAnimations(clear_quarantine)
    finishInteractiveMove(true)
    stopAllNativeAnimations(true)
    stopAllPositionAnimations(true)
    if clear_quarantine then clearQuarantinedWindows() end
end

---add or remove focused window from the floating layer and retile the space
---@param window Window|nil optional window to float and focus
function Windows.toggleFloating(window)
    window = window or Window.focusedWindow()
    if not window then
        Windows.PaperWM.logger.d("focused window not found")
        return
    end

    local id = window:id()
    if Windows.PaperWM.state.is_floating[id] then
        Windows.PaperWM.state.is_floating[id] = nil
    else
        Windows.PaperWM.state.is_floating[id] = true
    end
    Windows.persistFloatingList()

    local space = (function()
        if Windows.PaperWM.state.is_floating[id] then
            return Windows.removeWindow(window, true)
        else
            return Windows.addWindow(window)
        end
    end)()
    if space then
        window:focus()
        Windows.PaperWM:tileSpace(space)
    end
end

return Windows
