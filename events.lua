local Fnutils <const> = hs.fnutils
local Geometry <const> = hs.geometry
local LeftMouseDown <const> = hs.eventtap.event.types.leftMouseDown
local LeftMouseDragged <const> = hs.eventtap.event.types.leftMouseDragged
local LeftMouseUp <const> = hs.eventtap.event.types.leftMouseUp
local MouseEventDeltaX <const> = hs.eventtap.event.properties.mouseEventDeltaX
local MouseEventDeltaY <const> = hs.eventtap.event.properties.mouseEventDeltaY
local Screen <const> = hs.screen
local Spaces <const> = hs.spaces
local Timer <const> = hs.timer
local Watcher <const> = hs.uielement.watcher
local Window <const> = hs.window
local WindowFilter <const> = hs.window.filter

local Events = {}
Events.__index = Events

-- Window creation commonly emits windowVisible, windowFocused, and
-- windowsChanged back-to-back. Tile once after that burst instead of starting
-- and replacing several animations in the same run-loop turn.
local pending_layout_timers = {}
local pending_window_timers = {}
local swipe_active_spaces = {}
local layout_debounce <const> = 0.015

local function scheduleTile(self, space)
    if swipe_active_spaces[space] then return end
    local pending = pending_layout_timers[space]
    if pending then pending:stop() end

    pending_layout_timers[space] = Timer.doAfter(layout_debounce, function()
        pending_layout_timers[space] = nil
        if swipe_active_spaces[space] then return end
        self.space.tileSpace(space)
    end)
end

local function tileImmediately(self, space)
    if swipe_active_spaces[space] then return end
    local pending = pending_layout_timers[space]
    if pending then
        pending:stop()
        pending_layout_timers[space] = nil
    end
    self.space.tileSpace(space)
end

local function cancelPendingWindow(id)
    local timer = pending_window_timers[id]
    if timer then timer:stop() end
    pending_window_timers[id] = nil
end

local function schedulePendingWindow(self, window)
    local id = window:id()
    if pending_window_timers[id] then return end

    local timer
    timer = Timer.doAfter(Window.animationDuration, function()
        if pending_window_timers[id] ~= timer then return end
        pending_window_timers[id] = nil
        if self.state.index_table[id] then return end

        -- A transient window may disappear before its Space assignment
        -- catches up. Treat a stale AX object like a cancelled retry.
        local ok, space = pcall(self.windows.addWindow, window)
        if ok and space then
            scheduleTile(self, space)
        elseif not ok then
            self.logger.df("window %d disappeared before Space assignment: %s", id, space)
        end
    end)
    pending_window_timers[id] = timer
end

-- A live mouse resize/move emits a flood of AX events. Reflowing the whole
-- space on each one runs the full tiling pass far faster than the screen can
-- consume, and starting a per-window animation every event means neighbors
-- chase the drag with a stream of half-finished transitions. Instead, cap the
-- reflow to a steady rate and commit frames immediately (no animation) so
-- neighbors track the drag in lockstep.
local last_tile_times = {}
local resize_throttle <const> = 1 / 30

local function tileWithoutAnimation(self, space)
    local saved = Window.animationDuration
    Window.animationDuration = 0
    local ok, err = pcall(self.space.tileSpace, space)
    Window.animationDuration = saved
    if not ok then self.logger.ef("tileSpace failed during resize: %s", err) end
end

local function throttleTile(self, space)
    if swipe_active_spaces[space] then return end
    local pending = pending_layout_timers[space]
    if pending then
        pending:stop()
        pending_layout_timers[space] = nil
    end

    local now = Timer.secondsSinceEpoch()
    local elapsed = now - (last_tile_times[space] or 0)
    if elapsed >= resize_throttle then
        last_tile_times[space] = now
        tileWithoutAnimation(self, space)
    else
        pending_layout_timers[space] = Timer.doAfter(resize_throttle - elapsed, function()
            pending_layout_timers[space] = nil
            last_tile_times[space] = Timer.secondsSinceEpoch()
            tileWithoutAnimation(self, space)
        end)
    end
end

local pending_swipe_settles = {}
local active_swipe_inertia = nil
local last_swipe_status = nil
local default_swipe_settle_delay <const> = 0.25
local default_swipe_inertia_fps <const> = 120
local swipe_velocity_response <const> = 0.025
local swipe_release_max_age <const> = 0.2
local swipe_trace_path <const> = "/tmp/paperwm_swipe_trace.log"
local diagnostics_trace_path <const> = "/tmp/paperwm_diagnostics.log"
local diagnostics_trace_file = nil

local function traceDiagnostic(self, format, ...)
    if not self.diagnostics_trace or not diagnostics_trace_file then return end
    diagnostics_trace_file:write(string.format("%.6f ", Timer.secondsSinceEpoch()))
    diagnostics_trace_file:write(string.format(format, ...))
    diagnostics_trace_file:write("\n")
end

---append a compact diagnostic record from another PaperWM module
function Events.trace(format, ...)
    if Events.PaperWM then traceDiagnostic(Events.PaperWM, format, ...) end
end

local function traceSwipe(self, format, ...)
    if not self.swipe_debug_trace then return end
    local file = io.open(swipe_trace_path, "a")
    if not file then return end
    file:write(string.format("%.6f ", Timer.secondsSinceEpoch()))
    file:write(string.format(format, ...))
    file:write("\n")
    file:close()
end

local function traceSwipeStatus(self, phase)
    local status = last_swipe_status
    if not status then return end
    traceDiagnostic(self,
        "swipe phase=%s source=%s space=%s compositor=%s velocity=%.3f samples=%d age_ms=%.3f inertia_started=%s inertia_finished=%s skipped=%s",
        tostring(phase), tostring(status.source), tostring(status.space),
        tostring(status.compositor_active), status.release_velocity or 0,
        status.velocity_samples or 0, status.release_age_ms or 0,
        tostring(status.inertia_started), tostring(status.inertia_finished),
        tostring(status.inertia_skipped))
end

local function startSpaceWatchers(self, space)
    for _, column in ipairs(self.state.window_list[space] or {}) do
        for _, window in ipairs(column) do
            local watcher = self.state.ui_watchers[window:id()]
            if watcher then watcher:start({ Watcher.windowMoved, Watcher.windowResized }) end
        end
    end
end

local function cancelActiveSwipeInertia(next_space)
    local inertia = active_swipe_inertia
    if not inertia then return end

    active_swipe_inertia = nil
    inertia.timer:stop()
    if last_swipe_status then last_swipe_status.inertia_interrupted = true end
    traceSwipeStatus(Events.PaperWM, "interrupted")
    local preserve_transform = next_space == inertia.space
    inertia.release(preserve_transform, false)
    if not preserve_transform then swipe_active_spaces[inertia.space] = nil end
end

---return metrics from the most recent swipe release or rejection
---@return table|nil
function Events.swipeStatus()
    if not last_swipe_status then return nil end
    local status = {}
    for key, value in pairs(last_swipe_status) do status[key] = value end
    status.inertia_active = active_swipe_inertia ~= nil
    return status
end

local function cancelPendingLayout(space)
    local pending = pending_layout_timers[space]
    if pending then
        pending:stop()
        pending_layout_timers[space] = nil
    end
end

local function cancelSwipeSettle(space)
    local pending = pending_swipe_settles[space]
    if pending then
        pending:stop()
        pending_swipe_settles[space] = nil
    end
end

local function scheduleSwipeSettle(self, space, screen_frame, retained_transform)
    cancelSwipeSettle(space)
    local delay = math.max(0, tonumber(self.swipe_settle_delay) or
        default_swipe_settle_delay)
    pending_swipe_settles[space] = Timer.doAfter(delay, function()
        pending_swipe_settles[space] = nil
        if retained_transform then self.windows.endInteractiveMove() end
        startSpaceWatchers(self, space)
        swipe_active_spaces[space] = nil

        local focused_window = Window.focusedWindow()
        if not focused_window then
            self.logger.e("no focused window at end of swipe")
            return
        end

        local frame = self.windows.getWindowFrame(focused_window)
        local visible_window = nil
        local focused_offscreen = false
        if frame.x < screen_frame.x then
            focused_offscreen = true
            visible_window = self.windows.getFirstVisibleWindow(
                space, screen_frame, self.windows.Direction.LEFT)
        elseif frame.x2 > screen_frame.x2 then
            focused_offscreen = true
            visible_window = self.windows.getFirstVisibleWindow(
                space, screen_frame, self.windows.Direction.RIGHT)
        end

        if visible_window then
            visible_window:focus()
        elseif focused_offscreen then
            self.space.tileSpace(space)
        end
    end)
end

---initialize module with reference to PaperWM
---@param paperwm PaperWM
function Events.init(paperwm)
    Events.PaperWM = paperwm
    Events.Swipe = dofile(hs.spoons.resourcePath("swipe.lua"))
end

---refresh window layout on screen change
local screen_watcher = Screen.watcher.new((function()
    local pending_timer = nil
    return function()
        if not pending_timer then
            pending_timer = Timer.doAfter(Window.animationDuration, function()
                pending_timer = nil
                Events.PaperWM.logger.d("refreshing window layout on screen change")
                Events.PaperWM.windows.refreshWindows()
            end)
        end
    end
end)())

---callback for window events
---@param window Window
---@param event string name of the event
---@param self PaperWM
function Events.windowEventHandler(window, event, self)
    if not window["id"] then
        self.logger.df("ignoring %s event without a window id: %s", event, window)
        return
    end

    -- Avoid synchronously asking the owning application for its title in the
    -- hot event path; a hung app can otherwise delay every window event.
    self.logger.df("%s for window id: %d", event, window:id())
    if event == "windowFocused" then
        self.windows.noteKeyboardFocusEvent(window)
    end
    -- hs.printf("%s for [%s] id: %d", event, window, window:id() or -1)
    local space = nil
    local tile_immediately = false
    local tile_throttled = false

    if event == "windowFocused" and
        self.windows.redirectTransientFocus(window) then
        return
    end

    if self.state.is_floating[window:id()] then
        -- this event is only meaningful for floating windows
        if event == "windowDestroyed" then
            self.state.is_floating[window:id()] = nil
            self.windows.persistFloatingList()
        end
        -- no other events are meaningful for floating windows
        return
    end

    if event == "windowFocused" then
        local index = self.state.index_table[window:id()]
        if not index then return end
        self.state.prev_focused_window = window -- for addWindow()
        space = index.space
        tile_immediately = true
    elseif event == "windowVisible" or event == "windowUnfullscreened" then
        local rejection_reason
        space, rejection_reason = self.windows.addWindow(window)
        if space then
            cancelPendingWindow(window:id())
        elseif rejection_reason == "no space" then
            schedulePendingWindow(self, window)
            return
        else
            cancelPendingWindow(window:id())
            return
        end
    elseif event == "windowNotVisible" or event == "windowDestroyed" then
        cancelPendingWindow(window:id())
        if self.state.index_table[window:id()] then
            space = self.windows.removeWindow(window)
        end
    elseif event == "windowFullscreened" then -- or event == "windowNotInCurrentSpace" then
        cancelPendingWindow(window:id())
        if self.state.index_table[window:id()] then
            space = self.windows.removeWindow(window, true) -- don't focus new window if fullscreened
        end
    elseif event == "AXWindowMoved" or event == "AXWindowResized" then
        -- This runs on every frame of a live drag/resize, so avoid the slow
        -- private-API space lookup and use the cached space when available.
        local index = self.state.index_table[window:id()]
        space = index and index.space or Spaces.windowSpaces(window)[1]
        tile_throttled = true
    elseif event == "windowsChanged" or event == "windowNotInCurrentSpace" then
        local all_windows = self.windows.PaperWM.window_filter:getWindows()
        local allowed_ids = {}
        for _, allowed_window in ipairs(all_windows) do
            allowed_ids[allowed_window:id()] = true
        end

        -- Collect before removing because removeWindowIndex mutates index_table.
        local removed = {}
        for id, index in pairs(self.state.index_table) do
            if not allowed_ids[id] then
                table.insert(removed, { id = id, index = index })
            end
        end
        for _, item in ipairs(removed) do
            local removed_space = self.windows.removeWindowIndex(item.index, item.id)
            if removed_space then scheduleTile(self, removed_space) end
        end

        local focused_window = Window.focusedWindow()
        local focused_index = focused_window and self.state.index_table[focused_window:id()]
        if focused_index then
            local screen = Screen(Spaces.spaceDisplay(focused_index.space))
            if screen then
                local frame = self.windows.getWindowFrame(focused_window)
                local screen_frame = screen:frame()
                local visible_window = (function()
                    if frame.x < screen_frame.x then
                        return self.windows.getFirstVisibleWindow(focused_index.space, screen_frame,
                            self.windows.Direction.LEFT)
                    elseif frame.x2 > screen_frame.x2 then
                        return self.windows.getFirstVisibleWindow(focused_index.space, screen_frame,
                            self.windows.Direction.RIGHT)
                    end
                end)()
                if visible_window then visible_window:focus() end
            end
        end
    end

    if space then
        if tile_throttled then
            throttleTile(self, space)
        elseif tile_immediately then
            tileImmediately(self, space)
            self.windows.noteKeyboardLayoutComplete(window)
        else
            scheduleTile(self, space)
        end
    end
end

---coroutine to slide all windows in a space by dx
---@param self PaperWM
---@param space Space
---@param screen_frame Frame
---@param gesture_started number|nil absolute time when gesture setup began
---@param initial_input_timestamp number|nil gesture begin timestamp in absolute nanoseconds
---@param initial_sample_timestamp number gesture begin callback time in absolute nanoseconds
local function slide_windows(self, space, screen_frame, gesture_started,
        initial_input_timestamp, initial_sample_timestamp, input_source)
    local left_margin  = screen_frame.x + self.screen_margin
    local right_margin = screen_frame.x2 - self.screen_margin

    -- Reuse cached Window objects; reconstructing each one by ID can make a
    -- synchronous Accessibility request before the first gesture frame.
    local windows = {}
    local x_positions = self.state.x_positions[space] or {}
    for _, column in ipairs(self.state.window_list[space] or {}) do
        for _, window in ipairs(column) do
            local id = window:id()
            local x = x_positions[id]
            if x then
                table.insert(windows, { window = window, x = x })
            end
        end
    end
    local compositor_active, swipe_blocked =
        self.windows.beginInteractiveMove(windows, gesture_started)
    traceSwipe(self, "compositor begin active=%s blocked=%s windows=%d",
        tostring(compositor_active), tostring(swipe_blocked), #windows)
    if swipe_blocked then return "blocked" end
    for _, item in ipairs(windows) do
        local watcher = self.state.ui_watchers[item.window:id()]
        if watcher then watcher:stop() end
    end

    local moved = false
    local velocity = 0
    local last_sample_timestamp = initial_sample_timestamp
    local velocity_samples = 0

    local function clampStripDelta(dx)
        if not compositor_active or dx == 0 or #windows == 0 then return dx end

        local content_left, content_right = math.huge, -math.huge
        for _, item in ipairs(windows) do
            content_left = math.min(content_left, item.x)
            content_right = math.max(content_right, item.x + item.frame.w)
        end
        return Events.Swipe.clampStripDelta(
            dx, content_left, content_right, left_margin, right_margin)
    end

    local function applyDelta(dx, input_timestamp)
        dx = clampStripDelta(dx)
        if dx == 0 then return 0 end

        moved = true
        for _, item in ipairs(windows) do
            item.x = item.x + dx
            -- Keep virtual strip positions unconstrained, but park real
            -- windows at this screen's edges just like normal tiling does.
            item.frame.x = math.max(left_margin - item.frame.w,
                math.min(item.x, right_margin))
        end
        if compositor_active then
            local updated, reason =
                self.windows.updateInteractiveMove(windows, input_timestamp)
            if not updated then
                traceSwipe(self, "compositor update failed reason=%s",
                    tostring(reason))
            end
            compositor_active = updated
        else
            for _, item in ipairs(windows) do
                item.window:setTopLeft(item.frame.x, item.frame.y)
            end
        end
        return dx
    end

    local function releaseOwnership(retain_transform, settle)
        local retained_transform = retain_transform and compositor_active and moved
        if compositor_active and not retained_transform then
            self.windows.endInteractiveMove()
        end

        for _, item in ipairs(windows) do
            local id = item.window:id()
            if moved then x_positions[id] = item.x end
            if not retained_transform then
                local watcher = self.state.ui_watchers[id]
                if watcher then watcher:start({ Watcher.windowMoved, Watcher.windowResized }) end
            end
        end
        windows = nil

        if settle then
            if moved then
                scheduleSwipeSettle(self, space, screen_frame, retained_transform)
            else
                swipe_active_spaces[space] = nil
            end
        end
    end

    local release_timestamp = nil
    local release_sample_timestamp = nil
    while true do
        local dx, input_timestamp, sample_timestamp = coroutine.yield()
        if dx == false then
            releaseOwnership(false, false)
            swipe_active_spaces[space] = nil
            return
        end
        if not dx then
            release_timestamp = input_timestamp
            release_sample_timestamp = sample_timestamp
            break
        end

        if dx ~= 0 then
            if sample_timestamp and last_sample_timestamp and
                sample_timestamp > last_sample_timestamp then
                velocity = Events.Swipe.velocitySample(
                    velocity, dx, (sample_timestamp - last_sample_timestamp) / 1000000000,
                    swipe_velocity_response)
                velocity_samples = velocity_samples + 1
                traceSwipe(self, "velocity sample=%d dx=%.3f dt_ms=%.3f velocity=%.3f",
                    velocity_samples, dx,
                    (sample_timestamp - last_sample_timestamp) / 1000000, velocity)
            end
            last_sample_timestamp = sample_timestamp
            applyDelta(dx, input_timestamp)
        end
    end

    local release_age = release_sample_timestamp and last_sample_timestamp and
        math.max(0, (release_sample_timestamp - last_sample_timestamp) / 1000000000) or 0
    local release_is_fresh = release_age <= swipe_release_max_age
    local min_velocity = math.max(1, tonumber(self.swipe_inertia_min_velocity) or 40)
    local max_velocity = math.max(min_velocity,
        tonumber(self.swipe_inertia_max_velocity) or 6000)
    velocity = math.max(-max_velocity, math.min(max_velocity, velocity))
    last_swipe_status = {
        space = space,
        source = input_source or "unknown",
        release_velocity = velocity,
        velocity_samples = velocity_samples,
        release_age_ms = release_age * 1000,
        event_begin_timestamp = initial_input_timestamp,
        event_release_timestamp = release_timestamp,
        compositor_active = compositor_active,
        inertia_started = false,
    }
    traceSwipe(self,
        "release moved=%s compositor=%s velocity=%.3f samples=%d age_ms=%.3f event_begin=%s event_end=%s",
        tostring(moved), tostring(compositor_active), velocity, velocity_samples,
        release_age * 1000, tostring(initial_input_timestamp), tostring(release_timestamp))

    if self.swipe_inertia and moved and release_is_fresh and
        math.abs(velocity) >= min_velocity then
        local friction = math.max(0.01,
            tonumber(self.swipe_inertia_friction) or 3.5)
        last_swipe_status.inertia_started = true
        traceSwipeStatus(self, "release")
        traceSwipe(self, "inertia start velocity=%.3f friction=%.3f", velocity, friction)
        local last_tick = Timer.secondsSinceEpoch()
        local inertia = { space = space }
        local inertia_ticks = 0

        function inertia.release(preserve_transform, settle)
            releaseOwnership(preserve_transform, settle)
        end

        local inertia_fps = tonumber(self.animation_fps) or
            default_swipe_inertia_fps
        if inertia_fps <= 0 or inertia_fps ~= inertia_fps then
            inertia_fps = default_swipe_inertia_fps
        end
        inertia.timer = Timer.new(1 / inertia_fps, function()
            local now = Timer.secondsSinceEpoch()
            local elapsed = math.max(0, math.min(0.05, now - last_tick))
            last_tick = now
            local dx
            dx, velocity = Events.Swipe.inertiaStep(velocity, elapsed, friction)
            local applied_dx = applyDelta(dx)
            inertia_ticks = inertia_ticks + 1
            if inertia_ticks == 1 or inertia_ticks % 10 == 0 then
                traceSwipe(self,
                    "inertia tick=%d dt_ms=%.3f dx=%.3f applied=%.3f velocity=%.3f",
                    inertia_ticks, elapsed * 1000, dx, applied_dx, velocity)
            end
            if applied_dx == 0 or math.abs(applied_dx) + 0.001 < math.abs(dx) then
                velocity = 0
                last_swipe_status.edge_clamped = true
                traceSwipe(self, "inertia edge clamp requested=%.3f applied=%.3f",
                    dx, applied_dx)
            end

            if math.abs(velocity) < min_velocity then
                inertia.timer:stop()
                if active_swipe_inertia == inertia then active_swipe_inertia = nil end
                last_swipe_status.inertia_finished = true
                traceSwipe(self, "inertia finish ticks=%d velocity=%.3f",
                    inertia_ticks, velocity)
                inertia.release(true, true)
                traceSwipeStatus(self, "finished")
            end
        end)
        active_swipe_inertia = inertia
        inertia.timer:start()
        return
    end

    if not self.swipe_inertia then
        last_swipe_status.inertia_skipped = "disabled"
    elseif not moved then
        last_swipe_status.inertia_skipped = "no horizontal movement"
    elseif not release_is_fresh then
        last_swipe_status.inertia_skipped = "release sample too old"
    else
        last_swipe_status.inertia_skipped = "release velocity below threshold"
    end
    traceSwipe(self, "inertia skipped reason=%s",
        tostring(last_swipe_status.inertia_skipped))
    traceSwipeStatus(self, "skipped")

    releaseOwnership(true, true)
end

local function beginSlide(self, gesture_started, input_timestamp,
        sample_timestamp, input_source)
    local focused_window = Window.focusedWindow()
    if not focused_window then
        self.logger.d("focused window not found")
        return nil, nil
    end

    local focused_index = self.state.index_table[focused_window:id()]
    if not focused_index then
        self.logger.e("focused index not found")
        return nil, nil
    end

    local screen = Screen(Spaces.spaceDisplay(focused_index.space))
    if not screen then
        self.logger.e("no screen for space")
        return nil, nil
    end

    cancelActiveSwipeInertia(focused_index.space)
    cancelPendingLayout(focused_index.space)
    cancelSwipeSettle(focused_index.space)

    local screen_frame = screen:frame()
    local swipe_coro = coroutine.wrap(slide_windows)
    local start_status = swipe_coro(
        self, focused_index.space, screen_frame, gesture_started,
        input_timestamp, sample_timestamp, input_source)
    if start_status == "blocked" then
        last_swipe_status = {
            space = focused_index.space,
            source = input_source,
            blocked = true,
            inertia_started = false,
            inertia_skipped = "native resize snap active",
        }
        traceSwipeStatus(self, "blocked")
        return nil, nil
    end
    swipe_active_spaces[focused_index.space] = true
    return swipe_coro, screen_frame
end

---generate callback function for touchpad swipe gesture event
---@param self PaperWM
function Events.swipeHandler(self)
    -- saved upvalues between callback function calls
    local swipe_coro, swipe_id, screen_frame, horizontal = nil, nil, nil, nil
    local horizontal_travel, vertical_travel, pending_dx = 0, 0, 0
    local haptic_distance = 0
    local gesture_started, begin_input_timestamp, begin_sample_timestamp

    ---callback for touchpad swipe gesture event
    ---@param id number unique id across callbacks for the same swipe
    ---@param type number one of Swipe.BEGIN, Swipe.MOVED, Swipe.END
    ---@param dx number change in horizonal position since last callback: between 0 and 1
    ---@param dy number change in vertical position since last callback: between 0 and 1
    return function(id, type, dx, dy, input_timestamp)
        local callback_timestamp = Timer.absoluteTime()
        traceSwipe(self,
            "callback id=%s type=%s dx=%.6f dy=%.6f event_ts=%s callback_ts=%s",
            tostring(id), tostring(type), dx, dy, tostring(input_timestamp),
            tostring(callback_timestamp))
        if type == Events.Swipe.BEGIN then
            -- Defensively close a recognizer lifecycle that did not deliver
            -- END before a replacement gesture. Do not acquire the new slide
            -- yet: macOS can emit zero-movement gesture fragments during a
            -- lift, and beginning one here would immediately cancel coasting.
            if swipe_coro then
                swipe_coro(nil, input_timestamp, callback_timestamp)
                swipe_coro = nil
            end

            -- cache upvalues
            swipe_id = id
            screen_frame = nil
            horizontal = nil
            horizontal_travel, vertical_travel, pending_dx = 0, 0, 0
            haptic_distance = 0
            gesture_started = callback_timestamp
            begin_input_timestamp = input_timestamp
            begin_sample_timestamp = callback_timestamp
        elseif swipe_id == id and type == Events.Swipe.END then
            if swipe_coro then
                self.logger.df("swipe end: %d", id)
                swipe_coro(nil, input_timestamp, callback_timestamp)
            else
                traceSwipe(self,
                    "candidate end ignored id=%s reason=no horizontal movement",
                    tostring(id))
            end
            swipe_coro = nil
            swipe_id = nil
            screen_frame = nil
            gesture_started = nil
            begin_input_timestamp = nil
            begin_sample_timestamp = nil
        elseif swipe_id == id and type == Events.Swipe.MOVED then
            if horizontal == nil then
                horizontal_travel = horizontal_travel + math.abs(dx)
                vertical_travel = vertical_travel + math.abs(dy)
                pending_dx = pending_dx + dx
                local direction = Events.Swipe.directionLock(
                    horizontal_travel, vertical_travel,
                    tonumber(self.swipe_direction_threshold) or 0.01)
                if direction ~= true then return end
                horizontal = true
                dx, pending_dx = pending_dx, 0

                -- Only meaningful horizontal input takes ownership from an
                -- active coast. This makes terminal touch fragments harmless
                -- while preserving intentional swipe-to-interrupt behavior.
                swipe_coro, screen_frame = beginSlide(
                    self, gesture_started, begin_input_timestamp,
                    begin_sample_timestamp, "trackpad")
                if not swipe_coro then
                    swipe_id = nil
                    return
                end
            end
            if not horizontal or not swipe_coro or not screen_frame then return end
            dx = self.swipe_gain * dx * screen_frame.w
            swipe_coro(dx, input_timestamp, callback_timestamp)

            local haptic_interval = tonumber(self.swipe_haptic_interval) or 0
            local haptic_ticks
            haptic_distance, haptic_ticks = Events.Swipe.distanceTicks(
                haptic_distance, dx, haptic_interval)
            for _ = 1, haptic_ticks do
                self.windows.performHapticFeedback()
            end
        end
    end
end


---generate a poll callback for passive HID++ gesture-button RawXY
---@param self PaperWM
function Events.mouseSwipePoll(self)
    local swipe_coro, horizontal = nil, nil
    local horizontal_travel, vertical_travel, haptic_distance = 0, 0, 0
    local pending_dx = 0
    local gesture_started = nil

    local function release(input_timestamp, sample_timestamp, cancel)
        if swipe_coro then
            swipe_coro(cancel and false or nil, input_timestamp, sample_timestamp)
        end
        swipe_coro, horizontal = nil, nil
        horizontal_travel, vertical_travel, haptic_distance = 0, 0, 0
        pending_dx, gesture_started = 0, nil
    end

    return function(stopping)
        if stopping then
            local timestamp = Timer.absoluteTime()
            release(timestamp, timestamp, true)
            return
        end

        local sample = self.windows.pollHIDPPGesture()
        if not sample then return end

        local sample_timestamp = Timer.absoluteTime()
        if sample.began then
            release(sample_timestamp, sample_timestamp)
            gesture_started = sample_timestamp
        end
        if sample.active and not gesture_started then
            gesture_started = sample_timestamp
        end

        local dx = tonumber(sample.dx) or 0
        local dy = tonumber(sample.dy) or 0
        if gesture_started and horizontal == nil and (dx ~= 0 or dy ~= 0) then
            horizontal_travel = horizontal_travel + math.abs(dx)
            vertical_travel = vertical_travel + math.abs(dy)
            pending_dx = pending_dx + dx
            horizontal = Events.Swipe.directionLock(
                horizontal_travel, vertical_travel,
                tonumber(self.mouse_swipe_direction_threshold) or 1)
        elseif horizontal and not swipe_coro then
            pending_dx = pending_dx + dx
        end

        if horizontal and not swipe_coro then
            swipe_coro = beginSlide(
                self, gesture_started, sample_timestamp, sample_timestamp,
                "options-hidpp")
            if swipe_coro then
                dx, pending_dx = pending_dx, 0
            end
        end

        if swipe_coro and dx ~= 0 then
            local gain = tonumber(self.mouse_swipe_gain) or 1
            if self.mouse_swipe_invert then gain = -gain end
            dx = gain * dx
            swipe_coro(dx, sample_timestamp, sample_timestamp)

            local haptic_ticks
            haptic_distance, haptic_ticks = Events.Swipe.distanceTicks(
                haptic_distance, dx,
                tonumber(self.swipe_haptic_interval) or 0)
            for _ = 1, haptic_ticks do
                self.windows.performHapticFeedback()
            end
        end

        if sample.ended then release(sample_timestamp, sample_timestamp) end
    end
end

---generate callback function for mouse events
---@param self PaperWM
function Events.mouseHandler(self)
    local lift_window, lift_items, lift_compositor, drag_coro = nil, nil, false, nil

    ---find a Window under the mouse cursor
    ---@param event userdata
    ---@return Window|nil
    local function windowUnderCursor(event)
        local cursor = Geometry.new(event:location())
        local screen = Fnutils.find(Screen.allScreens(), function(screen) return cursor:inside(screen:frame()) end)
        if not screen then return end
        local space = Spaces.activeSpaceOnScreen(screen)
        if not space then return end
        for id, _ in pairs(self.state.x_positions[space] or {}) do
            local window = Window(id)
            if window and cursor:inside(self.windows.getWindowFrame(window)) then
                return window
            end
        end
    end

    ---callback for mouse event
    ---@param event userdata
    ---@return boolean delete or propagate event
    return function(event)
        local delete_event = false
        local type = event:getType()
        if type == LeftMouseDown then
            local flags = event:getFlags()
            if self.drag_window and flags:containExactly(self.drag_window) then
                local drag_window = windowUnderCursor(event)
                if drag_window then
                    local index = self.state.index_table[drag_window:id()]
                    if not index then
                        self.logger.e("drag window index not found")
                        return delete_event
                    end
                    local screen = Screen(Spaces.spaceDisplay(index.space))
                    if not screen then
                        self.logger.e("no screen for space")
                        return delete_event
                    end
                    drag_coro = coroutine.wrap(slide_windows)
                    if drag_coro(self, index.space, screen:frame()) == "blocked" then
                        drag_coro = nil
                    else
                        self.logger.df("drag window start for: %s", drag_window)
                        delete_event = true
                    end
                end
            elseif self.lift_window and flags:containExactly(self.lift_window) then
                -- get window from cursor location, set window to floating, tile
                lift_window = windowUnderCursor(event)
                if lift_window then
                    self.windows.toggleFloating(lift_window)
                    lift_items = {
                        { window = lift_window,
                          frame = self.windows.getWindowFrame(lift_window) },
                    }
                    local lift_blocked
                    lift_compositor, lift_blocked =
                        self.windows.beginInteractiveMove(lift_items)
                    if lift_blocked then
                        lift_window = nil
                        lift_items = nil
                    end
                end
                self.logger.df("lift window start for: %s", lift_window)
                delete_event = true
            end
        elseif type == LeftMouseDragged then
            if drag_coro then
                drag_coro(event:getProperty(MouseEventDeltaX), event:timestamp())
                delete_event = true
            elseif lift_window then
                local frame = lift_items[1].frame
                frame.x = frame.x + event:getProperty(MouseEventDeltaX)
                frame.y = frame.y + event:getProperty(MouseEventDeltaY)
                if lift_compositor then
                    lift_compositor = self.windows.updateInteractiveMove(
                        lift_items, event:timestamp())
                else
                    lift_window:setTopLeft(frame.x, frame.y)
                end
                delete_event = true
            end
        elseif type == LeftMouseUp then
            if drag_coro then
                self.logger.df("drag window stop")
                drag_coro(nil)
                drag_coro = nil
                delete_event = true
            elseif lift_window then
                -- set window to not floating, tile
                self.logger.df("lift window stop")
                if lift_compositor then self.windows.endInteractiveMove() end
                self.windows.toggleFloating(lift_window)
                lift_window = nil
                lift_items = nil
                lift_compositor = false
                delete_event = true
            end
        end
        return delete_event
    end
end

---start monitoring for window events
function Events.start()
    if diagnostics_trace_file then diagnostics_trace_file:close() end
    diagnostics_trace_file = nil
    if Events.PaperWM.diagnostics_trace then
        diagnostics_trace_file = io.open(diagnostics_trace_path, "w")
        if diagnostics_trace_file then
            diagnostics_trace_file:setvbuf("line")
            diagnostics_trace_file:write("PaperWM diagnostics\n")
            local animation_ok, animation_reason =
                Events.PaperWM.windows.nativeAnimationStatus()
            local interactive_ok, interactive_reason =
                Events.PaperWM.windows.nativeInteractiveStatus()
            traceDiagnostic(Events.PaperWM,
                "startup animation_native=%s animation_reason=%s interactive_native=%s interactive_reason=%s",
                tostring(animation_ok), tostring(animation_reason),
                tostring(interactive_ok), tostring(interactive_reason))
        end
    end

    if Events.PaperWM.swipe_debug_trace then
        local file = io.open(swipe_trace_path, "w")
        if file then
            file:write("PaperWM swipe trace\n")
            file:close()
        end
        Events.Swipe.trace = function(format, ...)
            traceSwipe(Events.PaperWM, format, ...)
        end
    else
        Events.Swipe.trace = nil
    end

    -- listen for window events
    Events.PaperWM.window_filter:subscribe({
        WindowFilter.windowFocused, WindowFilter.windowVisible,
        WindowFilter.windowHidden, WindowFilter.windowMinimized,
        WindowFilter.windowNotVisible, WindowFilter.windowFullscreened,
        WindowFilter.windowUnfullscreened, WindowFilter.windowDestroyed,
        WindowFilter.windowNotInCurrentSpace, -- WindowFilter.windowInCurrentSpace,
        WindowFilter.windowsChanged,
    }, function(window, _, event) Events.windowEventHandler(window, event, Events.PaperWM) end)

    -- watch for external monitor plug / unplug
    screen_watcher:start()

    -- recognize horizontal touchpad swipe gestures
    if Events.PaperWM.swipe_fingers > 1 then
        Events.Swipe:start(Events.PaperWM.swipe_fingers, Events.swipeHandler(Events.PaperWM))
    end

    if Events.PaperWM.mouse_swipe then
        local started, reason = Events.PaperWM.windows.startHIDPPGestureMonitor(
            tonumber(Events.PaperWM.mouse_swipe_hidpp_feature_index) or 0x09,
            tonumber(Events.PaperWM.mouse_swipe_hidpp_cid) or 0x00c3)
        if started then
            Events.mouse_swipe_poll = Events.mouseSwipePoll(Events.PaperWM)
            Events.mouse_swipe_timer = Timer.new(
                tonumber(Events.PaperWM.mouse_swipe_poll_interval) or (1 / 120),
                Events.mouse_swipe_poll):start()
        else
            Events.PaperWM.logger.wf(
                "could not start passive HID++ gesture monitor: %s",
                tostring(reason))
        end
    end

    -- register a mouse event watcher if the drag window or lift window hotkeys are set
    if Events.PaperWM.drag_window or Events.PaperWM.lift_window then
        Events.mouse_watcher = hs.eventtap.new({ LeftMouseDown, LeftMouseDragged, LeftMouseUp },
            Events.mouseHandler(Events.PaperWM)):start()
    end
end

---stop monitoring for window events
function Events.stop()
    cancelActiveSwipeInertia(nil)

    -- stop events
    Events.PaperWM.window_filter:unsubscribeAll()
    for _, watcher in pairs(Events.PaperWM.state.ui_watchers) do watcher:stop() end
    screen_watcher:stop()
    for space, timer in pairs(pending_layout_timers) do
        timer:stop()
        pending_layout_timers[space] = nil
    end
    for id, timer in pairs(pending_window_timers) do
        timer:stop()
        pending_window_timers[id] = nil
    end
    for space, timer in pairs(pending_swipe_settles) do
        timer:stop()
        pending_swipe_settles[space] = nil
    end
    swipe_active_spaces = {}
    last_tile_times = {}

    -- stop listening for touchpad swipes
    Events.Swipe:stop()

    if diagnostics_trace_file then
        diagnostics_trace_file:close()
        diagnostics_trace_file = nil
    end

    if Events.mouse_swipe_timer then
        if Events.mouse_swipe_poll then Events.mouse_swipe_poll(true) end
        Events.mouse_swipe_timer:stop()
        Events.mouse_swipe_timer = nil
        Events.mouse_swipe_poll = nil
    end
    Events.PaperWM.windows.stopHIDPPGestureMonitor()

    -- stop listening for mouse events
    if Events.mouse_watcher then Events.mouse_watcher:stop() end
end

return Events
