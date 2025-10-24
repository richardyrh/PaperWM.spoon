local Screen <const> = hs.screen
local Spaces <const> = hs.spaces
local Timer <const> = hs.timer
local Watcher <const> = hs.uielement.watcher
local Window <const> = hs.window
local WindowFilter <const> = hs.window.filter

local Events = {}
Events.__index = Events

---initialize module with reference to PaperWM
---@param paperwm PaperWM
function Events.init(paperwm)
    Events.PaperWM = paperwm
    Events.Swipe = dofile(hs.spoons.resourcePath("swipe.lua"))
end

---refresh window layout on screen change
local screen_watcher = Screen.watcher.new(function() Events.PaperWM.windows.refreshWindows() end)

function count(tb)
    if tb then
        local c = 0
        for _, x in pairs(tb) do
            c = c + 1
        end
        return c
    else
        return 0
    end
end

local function has_value (tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end

    return false
end

---callback for window events
---@param window Window
---@param event string name of the event
---@param self PaperWM
function Events.windowEventHandler(window, event, self)
    if not window then
        return
    end

    self.logger.df("%s for [%s] id: %d", event, window, window:id() or -1)
    -- hs.printf("%s for [%s] id: %d", event, window, window:id() or -1)
    local space = nil

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
        space = Spaces.windowSpaces(window)[1]
    else
        -- print("event", event)
        local all_windows = self.windows.PaperWM.window_filter:getWindows()

        local retile_spaces = {} -- spaces that need to be retiled

        local cspace = hs.spaces.focusedSpace()
        local ac = #all_windows
        local bc = count(self.state.x_positions[cspace])
        local cc = count(self.state.index_table)
        hs.printf("I see %d windows in the filter list, %d in xpos, %d in the index table\n", ac, bc, cc)
        -- if ac ~= bc or bc ~= cc or ac ~= cc then
        -- end
        if event == "windowsChanged" or event == "windowNotInCurrentSpace" then
            -- print("cleanup start")
            -- print("all windows", hs.inspect(all_windows))
            -- print("x pos", hs.inspect(self.windows.PaperWM.state.x_positions))
            -- print("index table", hs.inspect(self.state.index_table))
            -- print("=================")
            for wid, window in pairs(self.state.index_table) do
                local exists = false
                for _, aw in ipairs(all_windows) do
                    -- print(aw:screen():id())
                    -- print(hs.inspect(window))
                    if aw:id() == wid then
                        exists = true
                    end
                end
                if not exists then
                    print("kicking out window", wid, hs.inspect(window))
                    space = self.windows.removeWindowIndex(window, wid)
                end

            end

            local focused_window = Window.focusedWindow()
            local focused_index = self.state.index_table[focused_window:id()]
            local screen = Screen(Spaces.spaceDisplay(focused_index.space))

            if focused_window then
                print("trying to focus")
                local frame = focused_window:frame()

                local screen_frame = screen:frame()
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
                    print("focusing")
                    visible_window:focus()
                end
            else
                print("no focused windows!!!!!")
            end
            -- -- find anchor window
            -- local focused_window = hs.window.focusedWindow()
            -- local anchor_window = (function()
            --     if focused_window and not Windows.PaperWM.state.is_floating[focused_window:id()] and Spaces.windowSpaces(focused_window)[1] == space then
            --         return focused_window
            --     else
            --         return self.windows.getFirstVisibleWindow(space, screen:frame())
            --     end
            -- end)()

        end

        -- for _, window in ipairs(all_windows) do
        --     local index = self.state.index_table[window:id()]
        --     if Windows.PaperWM.state.is_floating[window:id()] then
        --         -- ignore floating windows
        --     elseif not index then
        --         -- add window
        --         local space = Windows.addWindow(window)
        --         if space then retile_spaces[space] = true end
        --     elseif index.space ~= Spaces.windowSpaces(window)[1] then
        --         -- move to window list in new space, don't focus nearby window
        --         Windows.removeWindow(window, true)
        --         local space = Windows.addWindow(window)
        --         if space then retile_spaces[space] = true end
        --     end
        -- end
    
        -- -- retile spaces
        -- for space, _ in pairs(retile_spaces) do Windows.PaperWM:tileSpace(space) end

    end

    if space then self.space.tileSpace(space) end
end

---generate callback fucntion for touchpad swipe gesture event
---@param self PaperWM
function Events.swipeHandler(self)
    -- saved upvalues between callback function calls
    local space, screen_frame = nil, nil

    ---callback for touchpad swipe gesture event
    ---@param id number unique id across callbacks for the same swipe
    ---@param type number one of Swipe.BEGIN, Swipe.MOVED, Swipe.END
    ---@param dx number change in horizonal position since last callback: between 0 and 1
    ---@param dy number change in vertical position since last callback: between 0 and 1
    return function(id, type, dx, dy)
        if type == Events.Swipe.BEGIN then
            self.logger.df("new swipe: %d", id)

            if PaperWMHUD then
                PaperWMHUD.show(true, false)
            end

            -- use focused window for space to scroll windows
            local focused_window = Window.focusedWindow()
            if not focused_window then
                self.logger.d("focused window not found")
                return
            end

            -- get focused window index
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
            space        = focused_index.space

            -- stop all window moved watchers
            for window, _ in pairs(self.state.x_positions[space] or {}) do
                if not window then break end

                ----------------------------------------------------------
                ----------------------------------------------------------
                ----------------------------------------------------------
                ----------------------------------------------------------
                ----------------------------------------------------------
                -- local app = window:application()
                -- if app then
                --     local ax_app = hs.axuielement.applicationElement(app)
                --     if ax_app then
                --         ax_app.AXEnhancedUserInterface = false
                --     end
                -- end
                ----------------------------------------------------------
                ----------------------------------------------------------
                ----------------------------------------------------------
                ----------------------------------------------------------
                ----------------------------------------------------------

                local watcher = self.state.ui_watchers[window:id()]
                if watcher then
                    watcher:stop()
                end
            end
        elseif type == Events.Swipe.END then
            self.logger.df("swipe end: %d", id)

            if not space or not screen_frame then
                return -- no cached upvalues
            end

            -- if PaperWMHUD then
            --     PaperWMHUD.hide()
            -- end

            -- restart all window moved watchers
            for window, _ in pairs(self.state.x_positions[space] or {}) do
                if not window then break end
                local watcher = self.state.ui_watchers[window:id()]
                if watcher then
                    watcher:start({ Watcher.windowMoved, Watcher.windowResized })
                end
            end

            -- ensure a focused window is on screen
            local focused_window = Window.focusedWindow()
            if focused_window then
                local frame = focused_window:frame()
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

            -- clear cached upvalues
            space, screen_frame = nil, nil
        elseif type == Events.Swipe.MOVED then
            if not space or not screen_frame then
                return -- no cached upvalues
            end

            if math.abs(dy) >= math.abs(dx) then
                if dy > 0.005 then
                    if PaperWMHUD then
                        PaperWMHUD.show(false, true)
                        -- PaperWMHUD.fadeTimer:stop()
                        -- PaperWMHUD.fadeTimer = nil
                    end
                end
                return -- only handle horizontal swipes
            end

            if PaperWMHUD then
                PaperWMHUD.show(false, true)
                --PaperWMHUD.refresh()
            end

            dx = math.floor(self.swipe_gain * dx * screen_frame.w)

            local left_margin  = screen_frame.x + self.screen_margin
            local right_margin = screen_frame.x2 - self.screen_margin

            for window, x in pairs(self.state.x_positions[space] or {}) do
                if not window then break end
                x = x + dx
                local frame = window:frame()
                if dx > 0 then -- scroll right
                    frame.x = math.min(x, right_margin)
                else           -- scroll left
                    frame.x = math.max(x, left_margin - frame.w)
                end
                window:setTopLeft(frame.x, frame.y)       -- avoid the animationDuration
                self.state.x_positions[space][window] = x -- update virtual position
            end
        end
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
end

---stop monitoring for window events
function Events.stop()
    -- stop events
    Events.PaperWM.window_filter:unsubscribeAll()
    for _, watcher in pairs(Events.PaperWM.state.ui_watchers) do watcher:stop() end
    screen_watcher:stop()

    -- stop listening for touchpad swipes
    Events.Swipe:stop()
end

return Events
