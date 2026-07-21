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
local layout_debounce <const> = 0.015

local function scheduleTile(self, space)
    local pending = pending_layout_timers[space]
    if pending then pending:stop() end

    pending_layout_timers[space] = Timer.doAfter(layout_debounce, function()
        pending_layout_timers[space] = nil
        self.space.tileSpace(space)
    end)
end

local function tileImmediately(self, space)
    local pending = pending_layout_timers[space]
    if pending then
        pending:stop()
        pending_layout_timers[space] = nil
    end
    self.space.tileSpace(space)
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
        self.logger.ef("no id method for window %s in windowEventHandler", window)
        return
    end

    -- Avoid synchronously asking the owning application for its title in the
    -- hot event path; a hung app can otherwise delay every window event.
    self.logger.df("%s for window id: %d", event, window:id())
    -- hs.printf("%s for [%s] id: %d", event, window, window:id() or -1)
    local space = nil
    local tile_immediately = false
    local tile_throttled = false

    --[[ When a new window is created, We first get a windowVisible event but
    without a Space. Next we receive a windowFocused event for the window, but
    this also sometimes lacks a Space. Our approach is to store the window
    pending a Space in the pending_window variable and set a timer to try to add
    the window again later. Also schedule the windowFocused handler to run later
    after the window was added ]]
    --

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
        if self.state.pending_window and window == self.state.pending_window then
            Timer.doAfter(Window.animationDuration,
                function()
                    self.logger.vf("pending window timer for %s", window)
                    Events.windowEventHandler(window, event, self)
                end)
            return
        end
        self.state.prev_focused_window = window -- for addWindow()
        space = Spaces.windowSpaces(window)[1]
        tile_immediately = true
    elseif event == "windowVisible" or event == "windowUnfullscreened" then
        space = self.windows.addWindow(window)
        if self.state.pending_window and window == self.state.pending_window then
            self.state.pending_window = nil -- tried to add window for the second time
        elseif not space then
            self.state.pending_window = window
            Timer.doAfter(Window.animationDuration,
                function()
                    Events.windowEventHandler(window, event, self)
                end)
            return
        end
    elseif event == "windowNotVisible" then -- or event == "windowHidden" then
        space = self.windows.removeWindow(window)
    elseif event == "windowFullscreened" then -- or event == "windowNotInCurrentSpace" then
        space = self.windows.removeWindow(window, true) -- don't focus new window if fullscreened
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
        else
            scheduleTile(self, space)
        end
    end
end

---coroutine to slide all windows in a space by dx
---@param self PaperWM
---@param space Space
---@param screen_frame Frame
local function slide_windows(self, space, screen_frame)
    local left_margin  = screen_frame.x + self.screen_margin
    local right_margin = screen_frame.x2 - self.screen_margin

    -- cache windows, frame, and virtual x positions because window lookup is expensive
    -- stop window watchers
    local windows      = {}
    for id, x in pairs(self.state.x_positions[space] or {}) do
        local window = Window(id)
        if window then
            local watcher = self.state.ui_watchers[id]
            if watcher then watcher:stop() end
            local frame = self.windows.getWindowFrame(window)
            table.insert(windows, { window = window, frame = frame, x = x })
        end
    end
    local compositor_active = self.windows.beginInteractiveMove(windows)

    while true do
        local dx, input_timestamp = coroutine.yield()
        if not dx then break end

        if dx ~= 0 then
            for _, item in ipairs(windows) do
                item.x = item.x + dx                               -- scroll left or right
                item.frame.x = dx > 0 and math.min(item.x, right_margin) or math.max(item.x, left_margin - item.frame.w)
            end
            if compositor_active then
                compositor_active = self.windows.updateInteractiveMove(windows, input_timestamp)
            else
                for _, item in ipairs(windows) do
                    item.window:setTopLeft(item.frame.x, item.frame.y)
                end
            end
        end
    end

    if compositor_active then self.windows.endInteractiveMove() end

    -- start window watchers
    for _, item in ipairs(windows) do
        local watcher = self.state.ui_watchers[item.window:id()]
        if watcher then watcher:start({ Watcher.windowMoved, Watcher.windowResized }) end
    end
    windows = nil -- force collection

    -- ensure a focused window is on screen
    local focused_window = Window.focusedWindow()
    if focused_window then
        local frame = self.windows.getWindowFrame(focused_window)
        local visible_window = (function()
            if frame.x < screen_frame.x then
                return self.windows.getFirstVisibleWindow(space, screen_frame,
                    self.windows.Direction.LEFT)
            elseif frame.x2 > screen_frame.x2 then
                return self.windows.getFirstVisibleWindow(space, screen_frame,
                    self.windows.Direction.RIGHT)
            end
        end)()
        if visible_window then
            visible_window:focus()
        else
            self.space.tileSpace(space)
        end
    else
        self.logger.e("no focused window at end of swipe")
    end

    while true do
        self.logger.ef("resumed finished slide_windows coroutine with: %s", coroutine.yield())
    end
end

---generate callback function for touchpad swipe gesture event
---@param self PaperWM
function Events.swipeHandler(self)
    -- saved upvalues between callback function calls
    local swipe_coro, screen_frame, horizontal = nil, nil, nil

    ---callback for touchpad swipe gesture event
    ---@param id number unique id across callbacks for the same swipe
    ---@param type number one of Swipe.BEGIN, Swipe.MOVED, Swipe.END
    ---@param dx number change in horizonal position since last callback: between 0 and 1
    ---@param dy number change in vertical position since last callback: between 0 and 1
    return function(id, type, dx, dy, input_timestamp)
        if type == Events.Swipe.BEGIN then

            -- use focused window for space to scroll windows
            local focused_window = Window.focusedWindow()
            if not focused_window then
                self.logger.d("focused window not found")
                return
            end

            local focused_index = self.state.index_table[focused_window:id()]
            if not focused_index then
                self.logger.e("focused index not found")
                return
            end

            local screen = Screen(Spaces.spaceDisplay(focused_index.space))
            if not screen then
                self.logger.e("no screen for space")
                return
            end

            -- cache upvalues
            screen_frame = screen:frame()
            horizontal = nil
            swipe_coro = coroutine.wrap(slide_windows)
            swipe_coro(self, focused_index.space, screen_frame)
        elseif swipe_coro and type == Events.Swipe.END then
            self.logger.df("swipe end: %d", id)
            swipe_coro(nil)
            swipe_coro = nil
        elseif swipe_coro and screen_frame and type == Events.Swipe.MOVED then
            if horizontal == nil and (dx ~= 0 or dy ~= 0) then
                horizontal = math.abs(dx) > math.abs(dy)
            end
            if not horizontal then return end
            dx = self.swipe_gain * dx * screen_frame.w
            swipe_coro(dx, input_timestamp)
        end
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
                    drag_coro(self, index.space, screen:frame())
                    self.logger.df("drag window start for: %s", drag_window)
                    delete_event = true
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
                    lift_compositor = self.windows.beginInteractiveMove(lift_items)
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

    -- register a mouse event watcher if the drag window or lift window hotkeys are set
    if Events.PaperWM.drag_window or Events.PaperWM.lift_window then
        Events.mouse_watcher = hs.eventtap.new({ LeftMouseDown, LeftMouseDragged, LeftMouseUp },
            Events.mouseHandler(Events.PaperWM)):start()
    end
end

---stop monitoring for window events
function Events.stop()
    -- stop events
    Events.PaperWM.window_filter:unsubscribeAll()
    for _, watcher in pairs(Events.PaperWM.state.ui_watchers) do watcher:stop() end
    screen_watcher:stop()
    for space, timer in pairs(pending_layout_timers) do
        timer:stop()
        pending_layout_timers[space] = nil
    end
    last_tile_times = {}

    -- stop listening for touchpad swipes
    Events.Swipe:stop()

    -- stop listening for mouse events
    if Events.mouse_watcher then Events.mouse_watcher:stop() end
end

return Events
