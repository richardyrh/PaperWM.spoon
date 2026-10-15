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
local pending_canvas_updates = {}
local pending_window_timers = {}
local swipe_active_spaces = {}
local layout_debounce <const> = 0.015
local previous_shutdown_callback = nil
local hidpp_shutdown_callback = nil

local function installHIDPPShutdownCallback()
    if hidpp_shutdown_callback then return end
    previous_shutdown_callback = hs.shutdownCallback
    hidpp_shutdown_callback = function()
        Events.PaperWM.windows.stopHIDPPGestureMonitor()
        if previous_shutdown_callback then previous_shutdown_callback() end
    end
    hs.shutdownCallback = hidpp_shutdown_callback
end

local function removeHIDPPShutdownCallback()
    if hs.shutdownCallback == hidpp_shutdown_callback then
        hs.shutdownCallback = previous_shutdown_callback
    end
    hidpp_shutdown_callback = nil
    previous_shutdown_callback = nil
end

local function scheduleTile(self, space)
    if swipe_active_spaces[space] then return end
    local pending = pending_layout_timers[space]
    if pending then pending:stop() end

    pending_layout_timers[space] = Timer.doAfter(layout_debounce, function()
        pending_layout_timers[space] = nil
        if swipe_active_spaces[space] then return end
        local previous_canvas = pending_canvas_updates[space]
        pending_canvas_updates[space] = nil
        self.space.tileSpace(space, previous_canvas)
    end)
end

local function tileImmediately(self, space, previous_canvas, preferred_window)
    if previous_canvas then
        pending_canvas_updates[space] = pending_canvas_updates[space] or previous_canvas
    end
    if swipe_active_spaces[space] then return false end
    local pending = pending_layout_timers[space]
    if pending then
        pending:stop()
        pending_layout_timers[space] = nil
    end
    previous_canvas = pending_canvas_updates[space]
    pending_canvas_updates[space] = nil
    self.space.tileSpace(space, previous_canvas, nil, preferred_window)
    return true
end

---request a layout update, respecting ownership of an active swipe
---an active swipe applies the current configuration in its normal settle pass
---@param space Space
---@param previous_canvas Frame|nil usable bounds before a gap configuration change
---@param preferred_window Window|nil keyboard shortcut destination
function Events.retileSpace(space, previous_canvas, preferred_window)
    return tileImmediately(Events.PaperWM, space, previous_canvas, preferred_window)
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
-- reflow to a steady rate and batch native neighbor positions (no animation)
-- so they track the drag without synchronous AX writes on every tick.
local last_tile_times = {}
local resize_throttle <const> = 1 / 60
local native_drag_probe = nil

local function tileWithoutAnimation(self, space)
    local started_at = Timer.absoluteTime()
    local batching = Events.draggedWindowID(space) and
        self.windows.beginLiveReflow(space)
    local layout_started_at = Timer.absoluteTime()
    local saved = Window.animationDuration
    Window.animationDuration = 0
    local probe = native_drag_probe
    local live_screen = probe and probe.space == space and probe.screen
    local ok, err = pcall(self.space.tileSpace, space, nil, live_screen)
    local layout_ms = (Timer.absoluteTime() - layout_started_at) / 1000000
    Window.animationDuration = saved
    if batching then
        local ended, native_moved, moved_windows, move_error, profile =
            pcall(self.windows.endLiveReflow, ok)
        if not ended then
            move_error = native_moved
            native_moved, moved_windows = false, 0
            self.logger.ef("live reflow move failed: %s", move_error)
        end
        local probe = native_drag_probe
        if probe and probe.space == space then
            local elapsed_ms = (Timer.absoluteTime() - started_at) / 1000000
            probe.reflows = probe.reflows + 1
            probe.reflow_total_ms = probe.reflow_total_ms + elapsed_ms
            probe.reflow_max_ms = math.max(probe.reflow_max_ms, elapsed_ms)
            probe.layout_total_ms = probe.layout_total_ms + layout_ms
            probe.bounds_total_ms = probe.bounds_total_ms +
                ((profile and profile.bounds_ms) or 0)
            probe.move_total_ms = probe.move_total_ms +
                ((profile and profile.move_ms) or 0)
            if native_moved then
                probe.native_move_batches = probe.native_move_batches + 1
                probe.native_move_windows = probe.native_move_windows + moved_windows
            else
                probe.ax_fallback_batches = probe.ax_fallback_batches + 1
                probe.last_move_error = move_error
            end
        end
    end
    if not ok then self.logger.ef("tileSpace failed during resize: %s", err) end
end

local function throttleTile(self, space)
    if swipe_active_spaces[space] then return end
    local pending = pending_layout_timers[space]
    if pending then return end

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

local mouse_button_down = false
local drag_candidate_attempted = false
local drag_owner = nil
local last_drag_probe_status = nil
local pending_drag_releases = {}

local function retileVisibleSpace(self, space, preferred_window)
    local screen = Screen(Spaces.spaceDisplay(space))
    if screen and Spaces.activeSpaceOnScreen(screen) == space then
        tileImmediately(self, space, nil, preferred_window)
    end
end

local function finishDragRelease(self, window, confirmed_drag)
    local id = window:id()
    local release = { window = window }
    pending_drag_releases[id] = release
    local function reconcile(attempt)
        if pending_drag_releases[id] ~= release then return end
        if not self.state.index_table[id] then
            pending_drag_releases[id] = nil
            return
        end
        local current, previous = self.windows.reconcileWindowSpace(window)
        if current then
            if previous then
                if self.space.clearDragReleaseOnFocus then
                    self.space.clearDragReleaseOnFocus(previous, nil)
                end
                retileVisibleSpace(self, previous)
            end
            if (confirmed_drag and not release.settled) or previous then
                release.settled = true
                if self.space.rememberDragRelease then
                    self.space.rememberDragRelease(current, id)
                end
                retileVisibleSpace(self, current, window)
                if self.windows.flushNativeAnimationBatch then
                    self.windows.flushNativeAnimationBatch()
                end
            end
        end
        -- Mission Control can publish the destination after mouse-up. Check
        -- membership only at release, not at the drag sampling frequency.
        if attempt < 3 and not previous then
            release.timer = Timer.doAfter(0.1 * (attempt + 1), function()
                reconcile(attempt + 1)
            end)
        else
            pending_drag_releases[id] = nil
        end
    end
    reconcile(0)
end

local function dragProtectsWindow(id)
    return pending_drag_releases[id] or (mouse_button_down and
        ((drag_owner and drag_owner.window_id == id) or
         (native_drag_probe and native_drag_probe.window_id == id)))
end

local function stopNativeDragProbe(self, finish_layout)
    local probe = native_drag_probe
    if not probe then return end
    native_drag_probe = nil
    probe.timer:stop()
    local confirmed_drag = drag_owner and drag_owner.window_id == probe.window_id
    local pending = pending_layout_timers[probe.space]
    if pending and confirmed_drag then
        pending:stop()
        pending_layout_timers[probe.space] = nil
    end
    if self.windows.finishLiveReflow then
        self.windows.finishLiveReflow(probe.space)
    end
    if finish_layout then
        -- Mission Control can transfer a window without changing the bounds
        -- read by the probe. Reconcile that drop, but don't settle ordinary
        -- pointer movement unless it was a confirmed window drag.
        finishDragRelease(self, probe.window, confirmed_drag)
    end
    local elapsed = math.max(0.001, Timer.secondsSinceEpoch() - probe.started_at)
    last_drag_probe_status = {
        window_id = probe.window_id,
        space = probe.space,
        samples = probe.samples,
        changed_samples = probe.changed_samples,
        elapsed_ms = elapsed * 1000,
        sample_hz = probe.samples / elapsed,
        reflows = probe.reflows,
        reflow_hz = probe.reflows / elapsed,
        average_reflow_ms = probe.reflows > 0 and
            probe.reflow_total_ms / probe.reflows or 0,
        max_reflow_ms = probe.reflow_max_ms,
        average_layout_ms = probe.reflows > 0 and
            probe.layout_total_ms / probe.reflows or 0,
        average_bounds_ms = probe.reflows > 0 and
            probe.bounds_total_ms / probe.reflows or 0,
        average_move_ms = probe.reflows > 0 and
            probe.move_total_ms / probe.reflows or 0,
        native_move_batches = probe.native_move_batches,
        native_move_windows = probe.native_move_windows,
        ax_fallback_batches = probe.ax_fallback_batches,
        last_move_error = probe.last_move_error,
    }
    traceDiagnostic(self,
        "drag native poll window=%d space=%d samples=%d changed=%d elapsed_ms=%.1f sample_hz=%.1f reflow_hz=%.1f avg_reflow_ms=%.2f max_reflow_ms=%.2f avg_layout_ms=%.2f avg_bounds_ms=%.2f avg_move_ms=%.2f native_batches=%d ax_fallbacks=%d",
        probe.window_id, probe.space, probe.samples,
        probe.changed_samples, elapsed * 1000, probe.samples / elapsed,
        probe.reflows / elapsed,
        probe.reflows > 0 and probe.reflow_total_ms / probe.reflows or 0,
        probe.reflow_max_ms,
        probe.reflows > 0 and probe.layout_total_ms / probe.reflows or 0,
        probe.reflows > 0 and probe.bounds_total_ms / probe.reflows or 0,
        probe.reflows > 0 and probe.move_total_ms / probe.reflows or 0,
        probe.native_move_batches,
        probe.ax_fallback_batches)
end

---report the last completed native drag sampling cadence
function Events.dragProbeStatus()
    return last_drag_probe_status
end

---the window whose position is controlled by the pointer during a live drag
function Events.draggedWindowID(space)
    return mouse_button_down and drag_owner and drag_owner.space == space and
        drag_owner.window_id or nil
end

local function startNativeDragProbe(self, window, space, initial_bounds, immediate_tile)
    if not mouse_button_down or swipe_active_spaces[space] then return false end
    local id = window:id()
    local release = pending_drag_releases[id]
    if release then
        if release.timer then release.timer:stop() end
        pending_drag_releases[id] = nil
    end
    if native_drag_probe then
        if native_drag_probe.window_id == id then
            if native_drag_probe.from_mouse and immediate_tile ~= false then
                native_drag_probe.from_mouse = false
                drag_owner = { window_id = id, space = space, window = window }
                throttleTile(self, space)
            end
            return true
        end
        if native_drag_probe.from_mouse and
            native_drag_probe.changed_samples == 0 then
            -- The focus/overlap candidate was wrong. The first real AX move
            -- identifies the window the application is actually dragging.
            stopNativeDragProbe(self, false)
            drag_owner = nil
        else
            return native_drag_probe.space == space
        end
    end
    local bounds = initial_bounds or self.windows.nativeWindowBounds(id)
    if not bounds then return false end

    local fps = math.max(1, math.min(120, tonumber(self.drag_poll_fps) or 60))
    local probe = {
        window_id = id,
        window = window,
        space = space,
        screen = Screen(Spaces.spaceDisplay(space)),
        frame = bounds,
        started_at = Timer.secondsSinceEpoch(),
        samples = 0,
        changed_samples = 0,
        from_mouse = immediate_tile == false,
        reflows = 0,
        reflow_total_ms = 0,
        reflow_max_ms = 0,
        layout_total_ms = 0,
        bounds_total_ms = 0,
        move_total_ms = 0,
        native_move_batches = 0,
        native_move_windows = 0,
        ax_fallback_batches = 0,
    }
    native_drag_probe = probe
    if not probe.from_mouse then
        drag_owner = { window_id = id, space = space, window = window }
        local pending = pending_layout_timers[space]
        if pending then
            pending:stop()
            pending_layout_timers[space] = nil
        end
    end
    probe.timer = Timer.new(1 / fps, function()
        if not mouse_button_down or native_drag_probe ~= probe or
            not self.state.index_table[id] then
            stopNativeDragProbe(self, false)
            return
        end
        if probe.suspended then return end
        local current = self.windows.nativeWindowBounds(id)
        if not current then
            stopNativeDragProbe(self, false)
            return
        end
        probe.samples = probe.samples + 1
        if current.x ~= probe.frame.x or current.y ~= probe.frame.y or
            current.w ~= probe.frame.w or current.h ~= probe.frame.h then
            probe.frame = current
            probe.changed_samples = probe.changed_samples + 1
            -- Pointer motion inside a window (clicks/text selection) is not
            -- a window drag. Claim reflow only after its bounds actually move.
            drag_owner = { window_id = id, space = space, window = window }
            -- AX move notifications may arrive at a lower cadence than the
            -- WindowServer bounds. The native read supplies intermediate
            -- positions without another cross-process Accessibility call.
            throttleTile(self, space)
        end
    end):start()
    if immediate_tile ~= false then throttleTile(self, space) end
    return true
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
    if not preserve_transform then
        swipe_active_spaces[inertia.space] = nil
        if pending_canvas_updates[inertia.space] then tileImmediately(Events.PaperWM, inertia.space) end
    end
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

local function scheduleSwipeSettle(self, space, retained_transform, snap)
    cancelSwipeSettle(space)
    local delay = math.max(0, tonumber(self.swipe_settle_delay) or
        default_swipe_settle_delay)
    pending_swipe_settles[space] = Timer.doAfter(delay, function()
        pending_swipe_settles[space] = nil
        if retained_transform then self.windows.endInteractiveMove() end
        startSpaceWatchers(self, space)
        swipe_active_spaces[space] = nil

        local focused_window = Window.focusedWindow()

        -- A focus change during the settle delay belongs to the user, not to
        -- this swipe. Do not send focus back to an old window or another Space.
        if not snap or (focused_window and focused_window:id()) ~= snap.focus_id then
            local focused_index = focused_window and
                self.state.index_table[focused_window:id()]
            if focused_index and focused_index.space == space then
                -- The focus event could not reflow while the swipe owned this
                -- Space. Replay that layout now, anchored to the user's click.
                tileImmediately(self, space, nil, focused_window)
            elseif pending_canvas_updates[space] then
                tileImmediately(self, space)
            end
            return
        end
        local target_index = self.state.index_table[snap.target_id]
        if not target_index or target_index.space ~= space then
            tileImmediately(self, space)
            return
        end
        if snap.target_id ~= snap.anchor_id then
            snap.window:focus()
        else
            -- Normal tiling only clamps an offscreen anchor to the nearest
            -- edge. Restore its original position so small swipes cannot drift.
            self.windows.moveWindow(snap.window, snap.start_frame)
            tileImmediately(self, space)
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
    if event == "windowDestroyed" then
        self.windows.clearResizeBlacklist(window)
    end
    if event == "windowFocused" then
        if native_drag_probe and native_drag_probe.from_mouse and not drag_owner then
            -- Do not let the focus animation turn a click candidate into a
            -- false drag. A real drag can still be claimed by its AX move.
            stopNativeDragProbe(self, false)
        end
        self.windows.noteKeyboardFocusEvent(window)
        local focused_index = self.state.index_table[window:id()]
        if focused_index and self.space.clearDragReleaseOnFocus then
            self.space.clearDragReleaseOnFocus(focused_index.space, window:id())
        end
    end
    -- hs.printf("%s for [%s] id: %d", event, window, window:id() or -1)
    local space = nil
    local tile_immediately = false
    local tile_throttled = false
    local tile_polled = false

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
        if event ~= "windowDestroyed" and dragProtectsWindow(window:id()) then
            if native_drag_probe and native_drag_probe.window_id == window:id() then
                native_drag_probe.suspended = true
            end
            return
        end
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
        if self.windows.liveReflowOwnsWindow and
            self.windows.liveReflowOwnsWindow(window:id()) then
            return
        end
        -- This runs on every frame of a live drag/resize, so avoid the slow
        -- private-API space lookup and use the cached space when available.
        local index = self.state.index_table[window:id()]
        space = index and index.space or (Spaces.windowSpaces(window) or {})[1]
        if space then
            tile_polled = startNativeDragProbe(self, window, space)
            tile_throttled = not tile_polled
        end
    elseif event == "windowsChanged" or event == "windowNotInCurrentSpace" then
        local all_windows = self.windows.PaperWM.window_filter:getWindows()
        local allowed_ids = {}
        for _, allowed_window in ipairs(all_windows) do
            allowed_ids[allowed_window:id()] = true
        end

        -- Collect before removing because removeWindowIndex mutates index_table.
        local removed = {}
        for id, index in pairs(self.state.index_table) do
            if not allowed_ids[id] and not dragProtectsWindow(id) then
                table.insert(removed, { id = id, index = index })
            end
        end
        for _, item in ipairs(removed) do
            local removed_space = self.windows.removeWindowIndex(item.index, item.id)
            if removed_space then scheduleTile(self, removed_space) end
        end

        if mouse_button_down or next(pending_drag_releases) then return end
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
        if tile_polled then
            -- Native bounds polling owns live-drag reflow.
        elseif tile_throttled then
            throttleTile(self, space)
        elseif tile_immediately then
            if not (event == "windowFocused" and
                self.windows.keyboardLayoutAlreadyStarted(window) and
                not pending_canvas_updates[space]) then
                tileImmediately(self, space)
                self.windows.noteKeyboardLayoutComplete(window)
            end
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
        initial_input_timestamp, initial_sample_timestamp, input_source,
        anchor_id, focus_id)
    local left_margin  = screen_frame.x + self.screen_margin
    local right_margin = screen_frame.x2 - self.screen_margin

    -- Reuse cached Window objects; reconstructing each one by ID can make a
    -- synchronous Accessibility request before the first gesture frame.
    local windows = {}
    local anchor_frame
    local x_positions = self.state.x_positions[space] or {}
    for col, column in ipairs(self.state.window_list[space] or {}) do
        for row, window in ipairs(column) do
            local id = window:id()
            local x = x_positions[id]
            if x then
                table.insert(windows, { window = window, id = id, col = col, row = row, x = x })
            end
        end
    end
    local compositor_active, swipe_blocked =
        self.windows.beginInteractiveMove(windows, gesture_started)
    traceSwipe(self, "compositor begin active=%s blocked=%s windows=%d",
        tostring(compositor_active), tostring(swipe_blocked), #windows)
    if swipe_blocked then return "blocked" end
    if not anchor_id then
        local best_visible = -1
        for _, item in ipairs(windows) do
            local visible = Events.Swipe.visibleFraction(
                item.x, item.frame.w, left_margin, right_margin)
            if visible > best_visible then
                anchor_id, best_visible = item.id, visible
            end
        end
    end
    for _, item in ipairs(windows) do
        if item.id == anchor_id then anchor_frame = Geometry.rect(item.frame) end
        item.applied_x = item.frame and item.frame.x or item.x
        local watcher = self.state.ui_watchers[item.window:id()]
        if watcher then watcher:stop() end
    end

    local moved = false
    local net_delta = 0
    local cancelled = false
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
        net_delta = net_delta + dx
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
                if math.abs(item.frame.x - item.applied_x) > 0.5 then
                    item.window:setTopLeft(item.frame.x, item.frame.y)
                    item.applied_x = item.frame.x
                end
            end
        end
        return dx
    end

    local function releaseOwnership(retain_transform, settle)
        local retained_transform = retain_transform and compositor_active and moved
        if compositor_active and not retained_transform then
            self.windows.endInteractiveMove()
        end

        local snap
        if settle and moved and anchor_frame then
            local candidates = {}
            for _, item in ipairs(windows) do
                table.insert(candidates, {
                    id = item.id, col = item.col, row = item.row,
                    x = item.x, w = item.frame.w, window = item.window,
                })
            end
            local target, anchor_visible, target_visible = Events.Swipe.snapTarget(
                candidates, anchor_id, cancelled and 0 or net_delta,
                left_margin, right_margin)
            if target then
                snap = {
                    anchor_id = anchor_id, target_id = target.id,
                    window = target.window, start_frame = anchor_frame,
                    focus_id = focus_id,
                }
                if last_swipe_status then
                    last_swipe_status.snap_anchor_id = anchor_id
                    last_swipe_status.snap_target_id = target.id
                    last_swipe_status.snap_anchor_visible = anchor_visible
                    last_swipe_status.snap_target_visible = target_visible
                    last_swipe_status.net_delta = net_delta
                end
                traceDiagnostic(self,
                    "swipe snap anchor=%d target=%d anchor_visible=%.3f target_visible=%.3f delta=%.3f cancelled=%s",
                    anchor_id, target.id, anchor_visible, target_visible,
                    net_delta, tostring(cancelled))
            end
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
                scheduleSwipeSettle(self, space, retained_transform, snap)
            else
                swipe_active_spaces[space] = nil
                if pending_canvas_updates[space] then tileImmediately(self, space) end
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
            if pending_canvas_updates[space] then tileImmediately(self, space) end
            return
        end
        if not dx then
            release_timestamp = input_timestamp
            release_sample_timestamp = sample_timestamp
            break
        end
        if dx == "cancel" then
            cancelled = true
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
        cancelled = cancelled,
        net_delta = net_delta,
    }
    traceSwipe(self,
        "release moved=%s compositor=%s velocity=%.3f samples=%d age_ms=%.3f event_begin=%s event_end=%s",
        tostring(moved), tostring(compositor_active), velocity, velocity_samples,
        release_age * 1000, tostring(initial_input_timestamp), tostring(release_timestamp))

    -- Tiny trackpad flicks can have a high release velocity. Require actual
    -- travel before that velocity is allowed to carry the strip to a new window.
    local deliberate_travel = input_source ~= "trackpad" or math.abs(net_delta) >=
        math.max(0, tonumber(self.swipe_inertia_min_travel) or 0.025) *
        screen_frame.w * math.abs(tonumber(self.swipe_gain) or 1)
    if self.swipe_inertia and not cancelled and deliberate_travel and moved and
        release_is_fresh and math.abs(velocity) >= min_velocity then
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

    if cancelled then
        last_swipe_status.inertia_skipped = "cancelled touch sequence"
    elseif not self.swipe_inertia then
        last_swipe_status.inertia_skipped = "disabled"
    elseif not moved then
        last_swipe_status.inertia_skipped = "no horizontal movement"
    elseif not deliberate_travel then
        last_swipe_status.inertia_skipped = "insufficient deliberate travel"
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
    local focus_id = focused_window and focused_window:id()
    local focused_index = focus_id and self.state.index_table[focus_id]
    local screen, space
    if focused_index then
        space = focused_index.space
        screen = Screen(Spaces.spaceDisplay(space))
    else
        local cursor = Geometry.new(hs.mouse.absolutePosition())
        screen = Fnutils.find(Screen.allScreens(), function(candidate)
            return cursor:inside(candidate:frame())
        end)
        space = screen and Spaces.activeSpaceOnScreen(screen)
    end
    if not space or not self.state.window_list[space] then return nil, nil end
    if not screen then
        self.logger.e("no screen for space")
        return nil, nil
    end

    cancelActiveSwipeInertia(space)
    cancelPendingLayout(space)
    cancelSwipeSettle(space)

    local screen_frame = screen:frame()
    local swipe_coro = coroutine.wrap(slide_windows)
    local start_status = swipe_coro(
        self, space, screen_frame, gesture_started,
        input_timestamp, sample_timestamp, input_source,
        focused_index and focus_id or nil, focus_id)
    if start_status == "blocked" then
        last_swipe_status = {
            space = space,
            source = input_source,
            blocked = true,
            inertia_started = false,
            inertia_skipped = "native resize snap active",
        }
        traceSwipeStatus(self, "blocked")
        return nil, nil
    end
    swipe_active_spaces[space] = true
    return swipe_coro, screen_frame
end

---generate callback function for touchpad swipe gesture event
---@param self PaperWM
function Events.swipeHandler(self)
    -- saved upvalues between callback function calls
    local swipe_coro, swipe_id, screen_frame, horizontal = nil, nil, nil, nil
    local vertical_travel, pending_dx = 0, 0
    local haptic_distance = 0
    local gesture_started, begin_input_timestamp, begin_sample_timestamp

    ---callback for touchpad swipe gesture event
    ---@param id number unique id across callbacks for the same swipe
    ---@param type number one of Swipe.BEGIN, Swipe.MOVED, Swipe.END
    ---@param dx number change in horizonal position since last callback: between 0 and 1
    ---@param dy number change in vertical position since last callback: between 0 and 1
    return function(id, type, dx, dy, input_timestamp, touch_info)
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
            vertical_travel, pending_dx = 0, 0
            haptic_distance = 0
            gesture_started = callback_timestamp
            begin_input_timestamp = input_timestamp
            begin_sample_timestamp = callback_timestamp
        elseif swipe_id == id and type == Events.Swipe.END then
            if swipe_coro then
                self.logger.df("swipe end: %d", id)
                swipe_coro(touch_info and touch_info.cancelled and "cancel" or nil,
                    input_timestamp, callback_timestamp)
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
                vertical_travel = vertical_travel + math.abs(dy)
                pending_dx = pending_dx + dx
                local direction = Events.Swipe.directionLock(
                    math.abs(pending_dx), vertical_travel,
                    tonumber(self.swipe_direction_threshold) or 0.01,
                    tonumber(self.swipe_direction_ratio) or 1.5)
                if direction == false then horizontal = false; return end
                if direction ~= true or
                    (touch_info and not touch_info.coherent_horizontal) then return end
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


---generate a poll callback for HID++ gesture-button RawXY
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
                    local focused_window = Window.focusedWindow()
                    if drag_coro(self, index.space, screen:frame(), nil, nil, nil,
                            nil, drag_window:id(),
                            focused_window and focused_window:id()) == "blocked" then
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
        Events.Swipe:start(Events.PaperWM.swipe_fingers, Events.swipeHandler(Events.PaperWM), {
            finger_motion_ratio = Events.PaperWM.swipe_finger_motion_ratio,
        })
    end

    if Events.PaperWM.mouse_swipe then
        local started, reason = Events.PaperWM.windows.startHIDPPGestureMonitor(
            tonumber(Events.PaperWM.mouse_swipe_hidpp_feature_index) or 0x09,
            tonumber(Events.PaperWM.mouse_swipe_hidpp_cid) or 0x00c3)
        if started then
            installHIDPPShutdownCallback()
            Events.mouse_swipe_poll = Events.mouseSwipePoll(Events.PaperWM)
            Events.mouse_swipe_timer = Timer.new(
                tonumber(Events.PaperWM.mouse_swipe_poll_interval) or (1 / 120),
                Events.mouse_swipe_poll):start()
        else
            Events.PaperWM.logger.wf(
                "could not start HID++ gesture monitor: %s",
                tostring(reason))
        end
    end

    -- register a mouse event watcher if the drag window or lift window hotkeys are set
    if Events.PaperWM.drag_window or Events.PaperWM.lift_window then
        Events.mouse_watcher = hs.eventtap.new({ LeftMouseDown, LeftMouseDragged, LeftMouseUp },
            Events.mouseHandler(Events.PaperWM)):start()
    end

    -- Only sample native bounds while a physical mouse drag is in progress.
    -- This listener is passive and does not interfere with application drags.
    Events.drag_probe_watcher = hs.eventtap.new(
        { LeftMouseDown, LeftMouseDragged, LeftMouseUp },
        function(event)
            local event_type = event:getType()
            if event_type == LeftMouseDown then
                mouse_button_down = true
                drag_candidate_attempted = false
                drag_owner = nil
            elseif event_type == LeftMouseDragged then
                if mouse_button_down and not drag_candidate_attempted and
                    not native_drag_probe then
                    drag_candidate_attempted = true
                    local flags = event.getFlags and event:getFlags()
                    local custom_drag = flags and flags.containExactly and
                        ((Events.PaperWM.drag_window and
                            flags:containExactly(Events.PaperWM.drag_window)) or
                         (Events.PaperWM.lift_window and
                            flags:containExactly(Events.PaperWM.lift_window)))
                    if not custom_drag then
                        local point = event.location and event:location()
                        local window, space, bounds =
                            Events.PaperWM.windows.managedWindowAtPoint(point)
                        if window then
                            startNativeDragProbe(Events.PaperWM, window,
                                space, bounds, false)
                        end
                    end
                end
            else
                local released_space = drag_owner and drag_owner.space
                local released_window = drag_owner and drag_owner.window
                local had_probe = native_drag_probe ~= nil
                mouse_button_down = false
                drag_candidate_attempted = false
                stopNativeDragProbe(Events.PaperWM, true)
                drag_owner = nil
                if released_space and not had_probe then
                    if Events.PaperWM.windows.finishLiveReflow then
                        Events.PaperWM.windows.finishLiveReflow(released_space)
                    end
                    finishDragRelease(Events.PaperWM, released_window, true)
                end
            end
            return false
        end):start()
end

---stop monitoring for window events
function Events.stop()
    for _, release in pairs(pending_drag_releases) do
        if release.timer then release.timer:stop() end
    end
    pending_drag_releases = {}
    cancelActiveSwipeInertia(nil)
    mouse_button_down = false
    drag_candidate_attempted = false
    stopNativeDragProbe(Events.PaperWM, false)
    drag_owner = nil

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
    pending_canvas_updates = {}
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
    removeHIDPPShutdownCallback()

    -- stop listening for mouse events
    if Events.mouse_watcher then Events.mouse_watcher:stop() end
    if Events.drag_probe_watcher then
        Events.drag_probe_watcher:stop()
        Events.drag_probe_watcher = nil
    end
end

return Events
