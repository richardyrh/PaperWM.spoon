---@diagnostic disable

describe("PaperWM swipe settlement", function()
    local saved_hs, Events, paperwm, focused, windows, callback, now
    local delayed, repeating, moves, begin_calls, end_calls, tile_calls

    before_each(function()
        saved_hs = _G.hs
        delayed, repeating, moves = {}, {}, {}
        begin_calls, end_calls, tile_calls, now = 0, 0, 0, 1000000000
        local function rect(x, y, w, h)
            if type(x) == "table" then x, y, w, h = x.x, x.y, x.w, x.h end
            return { x = x, y = y, w = w, h = h, x2 = x + w, y2 = y + h }
        end
        local function timer(callback)
            return { callback = callback, start = function(self) self.active = true; return self end,
                stop = function(self) self.active = false end }
        end
        local screen = { frame = function() return rect(0, 0, 1000, 800) end }
        _G.hs = {
            fnutils = { find = function(items, predicate)
                for _, item in ipairs(items) do
                    if predicate(item) then return item end
                end
            end }, geometry = { rect = rect, new = function(point)
                return { inside = function(_, frame)
                    return point.x >= frame.x and point.x < frame.x2 and
                        point.y >= frame.y and point.y < frame.y2
                end }
            end },
            math = { randomFromRange = function() return 123 end },
            eventtap = { event = { types = { gesture = 1 }, properties = {} } },
            uielement = { watcher = { windowMoved = 1, windowResized = 2 } },
            spaces = { spaceDisplay = function() return "screen" end,
                activeSpaceOnScreen = function() return 1 end },
            mouse = { absolutePosition = function() return { x = 500, y = 400 } end },
            screen = setmetatable({ watcher = { new = function() return timer(function() end) end },
                    allScreens = function() return { screen } end },
                { __call = function() return screen end }),
            window = { filter = {}, focusedWindow = function() return focused end },
            spoons = { resourcePath = function(file) return file end },
            timer = {
                absoluteTime = function() return now end,
                secondsSinceEpoch = function() return now / 1000000000 end,
                doAfter = function(_, callback)
                    local pending = timer(callback):start()
                    table.insert(delayed, pending)
                    return pending
                end,
                new = function(_, callback)
                    local pending = timer(callback)
                    table.insert(repeating, pending)
                    return pending
                end,
            },
        }
        windows = {}
        for id = 1, 3 do
            local window = { frame_value = rect((id - 1) * 1010, 0, 1000, 800) }
            window.id = function() return id end
            window.focus = function(self) focused = self end
            windows[id] = window
        end
        focused = windows[1]
        paperwm = {
            screen_margin = 0, swipe_gain = 1, swipe_haptic_interval = 0,
            swipe_inertia = false, swipe_settle_delay = 0.25,
            state = { window_list = { [1] = { { windows[1] }, { windows[2] }, { windows[3] } } },
                x_positions = { [1] = { [1] = 0, [2] = 1010, [3] = 2020 } },
                index_table = { [1] = { space = 1 }, [2] = { space = 1 }, [3] = { space = 1 } },
                ui_watchers = {} },
            logger = { d = function() end, e = function() end, df = function() end },
            space = { tileSpace = function() tile_calls = tile_calls + 1 end },
            windows = {
                noteKeyboardFocusEvent = function() end,
                redirectTransientFocus = function() return false end,
                keyboardLayoutAlreadyStarted = function() return false end,
                noteKeyboardLayoutComplete = function() end,
                beginInteractiveMove = function(items)
                    begin_calls = begin_calls + 1
                    for _, item in ipairs(items) do item.frame = rect(item.window.frame_value) end
                    return true, false
                end,
                updateInteractiveMove = function(items)
                    for _, item in ipairs(items) do item.window.frame_value = rect(item.frame) end
                    return true
                end,
                endInteractiveMove = function() end_calls = end_calls + 1 end,
                moveWindow = function(window, frame)
                    moves[window:id()] = rect(frame)
                    window.frame_value = rect(frame)
                end,
            },
        }
        Events = dofile("events.lua")
        Events.init(paperwm)
        callback = Events.swipeHandler(paperwm)
    end)

    after_each(function() _G.hs = saved_hs end)

    local function send(kind, dx, dy, info)
        now = now + 10000000
        callback(123, kind, dx or 0, dy or 0, now, info or { coherent_horizontal = true })
    end

    local function settle()
        for _, timer in ipairs(delayed) do if timer.active then timer.callback() end end
    end

    it("snaps small movements back to the exact initial position", function()
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.02)
        send(Events.Swipe.END)
        settle()
        assert.are.equal(windows[1], focused)
        assert.are.equal(0, moves[1].x)
        assert.are.equal(1, tile_calls)
        assert.are.equal(1, end_calls)
        assert.are.equal(1, Events.swipeStatus().snap_target_id)
    end)

    it("defers gap reflow during a swipe and preserves bounds from the first toggle", function()
        local received_canvas
        paperwm.space.tileSpace = function(_, canvas) received_canvas = canvas; tile_calls = tile_calls + 1 end
        local original_canvas = { x = 0, y = 0, w = 1000, h = 800 }
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.02)
        Events.retileSpace(1, original_canvas)
        Events.retileSpace(1, { x = 8, y = 0, w = 984, h = 792 })
        assert.are.equal(0, tile_calls)
        send(Events.Swipe.END)
        settle()
        assert.are.equal(1, tile_calls)
        assert.are.equal(original_canvas, received_canvas)
    end)

    it("applies pending gap changes even when the swipe never moves the strip", function()
        paperwm.swipe_gain = 0
        local received_canvas
        paperwm.space.tileSpace = function(_, canvas) received_canvas = canvas; tile_calls = tile_calls + 1 end
        local original_canvas = { x = 0, y = 0, w = 1000, h = 800 }
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.02)
        Events.retileSpace(1, original_canvas)
        assert.are.equal(0, tile_calls)
        send(Events.Swipe.END)
        assert.are.equal(1, tile_calls)
        assert.are.equal(original_canvas, received_canvas)
    end)

    it("focuses the next window only after it wins the visibility comparison", function()
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.6)
        send(Events.Swipe.END)
        assert.are.equal(windows[1], focused)
        settle()
        assert.are.equal(windows[2], focused)
        assert.are.equal(2, Events.swipeStatus().snap_target_id)
    end)

    it("starts on the pointer's managed Space without stealing unmanaged focus on a small swipe", function()
        local unmanaged = { id = function() return 99 end }
        focused = unmanaged
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.02)
        send(Events.Swipe.END)
        assert.are.equal(1, begin_calls)
        settle()
        assert.are.equal(unmanaged, focused)
        assert.are.equal(1, Events.swipeStatus().snap_anchor_id)
        assert.are.equal(1, Events.swipeStatus().snap_target_id)
        assert.are.equal(0, moves[1].x)
    end)

    it("focuses the next managed window after a deliberate swipe from unmanaged focus", function()
        focused = { id = function() return 99 end }
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.6)
        send(Events.Swipe.END)
        settle()
        assert.are.equal(windows[2], focused)
    end)

    it("starts a Logitech gesture from unmanaged focus on the pointer's Space", function()
        focused = { id = function() return 99 end }
        local samples = {
            { began = true, active = true, dx = -600, dy = 0 },
            { ended = true, dx = 0, dy = 0 },
        }
        paperwm.windows.pollHIDPPGesture = function()
            return table.remove(samples, 1)
        end
        local poll = Events.mouseSwipePoll(paperwm)
        poll()
        poll()
        assert.are.equal(1, begin_calls)
        settle()
        assert.are.equal(windows[2], focused)
    end)

    it("does not override a user focus change during the settle delay", function()
        local preferred
        paperwm.state.is_floating = {}
        paperwm.space.tileSpace = function(_, _, _, anchor)
            tile_calls = tile_calls + 1
            preferred = anchor
        end
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.02)
        send(Events.Swipe.END)
        focused = windows[3]
        Events.windowEventHandler(focused, "windowFocused", paperwm)
        assert.are.equal(0, tile_calls)
        settle()
        assert.are.equal(windows[3], focused)
        assert.is_nil(moves[1])
        assert.are.equal(1, tile_calls)
        assert.are.equal(windows[3], preferred)
    end)

    it("rejects diagonal intent and incoherent fingers before starting a native move", function()
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, 0.02, 0.018)
        assert.are.equal(0, begin_calls)
        send(Events.Swipe.END)
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.04, 0, { coherent_horizontal = false })
        assert.are.equal(0, begin_calls)
        send(Events.Swipe.MOVED, -0.01)
        assert.are.equal(1, begin_calls)
    end)

    it("prevents a tiny fast flick from coasting to another window", function()
        paperwm.swipe_inertia = true
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.02)
        send(Events.Swipe.END)
        local status = Events.swipeStatus()
        assert.is_true(math.abs(status.release_velocity) > 40)
        assert.is_false(status.inertia_started)
        assert.are.equal("insufficient deliberate travel", status.inertia_skipped)
        settle()
        assert.are.equal(windows[1], focused)
    end)

    it("preserves coasting and chooses visibility after the coast finishes", function()
        paperwm.swipe_inertia = true
        paperwm.swipe_inertia_max_velocity = 1500
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.3)
        send(Events.Swipe.END)
        assert.is_true(Events.swipeStatus().inertia_started)
        assert.is_nil(Events.swipeStatus().snap_target_id)
        for _ = 1, 300 do
            now = now + 10000000
            if repeating[1].active then repeating[1].callback() end
        end
        assert.is_true(Events.swipeStatus().inertia_finished)
        assert.are.equal(2, Events.swipeStatus().snap_target_id)
        settle()
        assert.are.equal(windows[2], focused)
    end)

    it("returns cancelled touch sequences to the original window without coasting", function()
        paperwm.swipe_inertia = true
        send(Events.Swipe.BEGIN)
        send(Events.Swipe.MOVED, -0.6)
        send(Events.Swipe.END, 0, 0, { cancelled = true })
        assert.is_true(Events.swipeStatus().cancelled)
        assert.is_false(Events.swipeStatus().inertia_started)
        settle()
        assert.are.equal(windows[1], focused)
        assert.are.equal(0, moves[1].x)
    end)
end)
