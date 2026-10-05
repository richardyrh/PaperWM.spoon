---@diagnostic disable

describe("PaperWM native drag bounds probe", function()
    local saved_hs, Events, paperwm, now, bounds, tile_calls
    local button_tap, timers, window
    local tiled_spaces, active_space

    before_each(function()
        saved_hs = _G.hs
        now, tile_calls, timers = 1000, 0, {}
        tiled_spaces, active_space = {}, 1
        bounds = { x = 100, y = 24, w = 800, h = 700 }
        window = { id = function() return 42 end }
        local function timer(callback)
            return { callback = callback,
                start = function(self) self.active = true; return self end,
                stop = function(self) self.active = false end }
        end
        _G.hs = {
            fnutils = {}, geometry = {},
            eventtap = {
                event = { types = { gesture = 1, leftMouseDown = 2,
                    leftMouseDragged = 3, leftMouseUp = 4 }, properties = {} },
                new = function(_, callback)
                    button_tap = callback
                    return timer(callback)
                end,
            },
            uielement = { watcher = { windowMoved = 1, windowResized = 2 } },
            spaces = { windowSpaces = function() return { 1 } end,
                spaceDisplay = function() return "screen" end,
                activeSpaceOnScreen = function() return active_space end },
            screen = setmetatable({
                watcher = { new = function() return timer(function() end) end },
            }, { __call = function() return { frame = function()
                return { x = 0, y = 0, w = 1000, h = 800 }
            end } end }),
            window = { filter = {}, animationDuration = 0.5,
                focusedWindow = function() return window end },
            spoons = { resourcePath = function(file) return file end },
            timer = {
                absoluteTime = function() return now * 1000000000 end,
                secondsSinceEpoch = function() return now end,
                doAfter = function(_, callback)
                    local value = timer(callback):start()
                    timers[#timers + 1] = value
                    return value
                end,
                new = function(_, callback)
                    local value = timer(callback)
                    timers[#timers + 1] = value
                    return value
                end,
            },
        }
        paperwm = {
            drag_poll_fps = 60,
            swipe_fingers = 0,
            mouse_swipe = false,
            diagnostics_trace = false,
            state = { index_table = { [42] = { space = 1 } },
                ui_watchers = {}, is_floating = {} },
            logger = { df = function() end, ef = function() end },
            window_filter = { subscribe = function() end,
                unsubscribeAll = function() end },
            space = { tileSpace = function(space)
                tile_calls = tile_calls + 1
                tiled_spaces[#tiled_spaces + 1] = space
                assert.are.equal(Events.draggedWindowID(space) and 0 or 0.5,
                    hs.window.animationDuration)
            end },
            windows = {
                reconcileWindowSpace = function()
                    return paperwm.state.index_table[42].space
                end,
                nativeWindowBounds = function() return bounds end,
                managedWindowAtPoint = function(point)
                    if point and bounds and point.x >= bounds.x and
                        point.x < bounds.x + bounds.w and
                        point.y >= bounds.y and point.y < bounds.y + bounds.h then
                        return window, 1, bounds
                    end
                end,
                beginLiveReflow = function() return true end,
                endLiveReflow = function() return true, 1 end,
                stopHIDPPGestureMonitor = function() end,
            },
        }
        Events = dofile("events.lua")
        Events.init(paperwm)
        Events.start()
    end)

    after_each(function()
        Events.stop()
        _G.hs = saved_hs
    end)

    it("samples changed WindowServer bounds between AX notifications", function()
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        Events.windowEventHandler(window, "AXWindowMoved", paperwm)
        assert.are.equal(42, Events.draggedWindowID(1))
        assert.are.equal(1, tile_calls)
        now = now + 1 / 60
        bounds = { x = 115, y = 24, w = 800, h = 700 }
        for _, timer in ipairs(timers) do
            if timer.active and timer.callback then timer.callback() end
        end
        assert.are.equal(2, tile_calls)
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseUp end })
        assert.is_nil(Events.draggedWindowID(1))
        assert.are.equal(3, tile_calls)
        assert.are.equal(1, Events.dragProbeStatus().changed_samples)
        assert.are.equal(1, Events.dragProbeStatus().samples)
        assert.are.equal(2, Events.dragProbeStatus().native_move_batches)
        assert.are.equal(0, Events.dragProbeStatus().ax_fallback_batches)
    end)

    it("keeps the dragged window unsnapped through a transient bounds failure", function()
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        Events.windowEventHandler(window, "AXWindowMoved", paperwm)
        bounds = nil
        for _, timer in ipairs(timers) do
            if timer.active and timer.callback then timer.callback() end
        end
        assert.are.equal(42, Events.draggedWindowID(1))
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseUp end })
        assert.is_nil(Events.draggedWindowID(1))
        assert.are.equal(2, tile_calls)
    end)

    it("starts the probe on the first physical drag before any AX move event", function()
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        button_tap({
            getType = function() return hs.eventtap.event.types.leftMouseDragged end,
            location = function() return { x = 120, y = 40 } end,
        })
        assert.is_nil(Events.draggedWindowID(1))
        assert.are.equal(0, tile_calls)
        bounds = { x = 115, y = 24, w = 800, h = 700 }
        for _, timer in ipairs(timers) do
            if timer.active and timer.callback then timer.callback() end
        end
        assert.are.equal(42, Events.draggedWindowID(1))
        assert.are.equal(1, tile_calls)
    end)

    it("does not suppress click reflow or remember a drag when only the pointer moves", function()
        local remembered
        paperwm.space.rememberDragRelease = function(_, id) remembered = id end
        paperwm.windows.noteKeyboardFocusEvent = function() end
        paperwm.windows.redirectTransientFocus = function() return false end
        paperwm.windows.keyboardLayoutAlreadyStarted = function() return false end
        paperwm.windows.noteKeyboardLayoutComplete = function() end
        paperwm.space.tileSpace = function()
            tile_calls = tile_calls + 1
            assert.is_nil(Events.draggedWindowID(1))
        end
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDragged end,
            location = function() return { x = 120, y = 40 } end })
        Events.windowEventHandler(window, "windowFocused", paperwm)
        assert.are.equal(1, tile_calls)
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseUp end })
        assert.is_nil(remembered)
        assert.are.equal(1, tile_calls)
    end)

    it("corrects an early hit-test candidate when another window actually moves", function()
        local other = { id = function() return 43 end }
        paperwm.state.index_table[43] = { space = 1 }
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        button_tap({
            getType = function() return hs.eventtap.event.types.leftMouseDragged end,
            location = function() return { x = 120, y = 40 } end,
        })
        assert.is_nil(Events.draggedWindowID(1))
        Events.windowEventHandler(other, "AXWindowMoved", paperwm)
        assert.are.equal(43, Events.draggedWindowID(1))
    end)

    it("does not retile when keyboard navigation already started layout", function()
        paperwm.windows.noteKeyboardFocusEvent = function() end
        paperwm.windows.redirectTransientFocus = function() return false end
        paperwm.windows.keyboardLayoutAlreadyStarted = function() return true end
        paperwm.windows.noteKeyboardLayoutComplete = function()
            error("focus confirmation must not restart keyboard layout")
        end
        Events.windowEventHandler(window, "windowFocused", paperwm)
        assert.are.equal(0, tile_calls)
    end)

    it("ignores already queued AX feedback from a reflow-owned neighbor", function()
        paperwm.windows.liveReflowOwnsWindow = function(id) return id == 42 end
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        Events.windowEventHandler(window, "AXWindowMoved", paperwm)
        assert.is_nil(Events.draggedWindowID(1))
        assert.are.equal(0, tile_calls)
    end)

    it("retains a dragged window through Space visibility transitions", function()
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        Events.windowEventHandler(window, "AXWindowMoved", paperwm)
        Events.windowEventHandler(window, "windowNotVisible", paperwm)
        paperwm.windows.PaperWM = paperwm
        paperwm.window_filter.getWindows = function() return {} end
        Events.windowEventHandler(window, "windowsChanged", paperwm)
        assert.are.equal(1, paperwm.state.index_table[42].space)
        bounds = { x = 200, y = 24, w = 800, h = 700 }
        for _, timer in ipairs(timers) do
            if timer.active then timer.callback() end
        end
        assert.are.equal(1, tile_calls)
    end)

    it("animates release in the destination instead of writing the hidden source Space", function()
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        Events.windowEventHandler(window, "AXWindowMoved", paperwm)
        active_space = 2
        paperwm.windows.reconcileWindowSpace = function()
            paperwm.state.index_table[42].space = 2
            return 2, 1
        end
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseUp end })
        assert.are.equal(2, paperwm.state.index_table[42].space)
        assert.are.equal(2, tile_calls)
        assert.are.equal(2, tiled_spaces[2])
    end)

    it("rechecks Space membership after a delayed Mission Control drop", function()
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        Events.windowEventHandler(window, "AXWindowMoved", paperwm)
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseUp end })
        active_space = 2
        paperwm.windows.reconcileWindowSpace = function()
            paperwm.state.index_table[42].space = 2
            return 2, 1
        end
        local release_timer = timers[#timers]
        release_timer.callback()
        assert.are.equal(2, paperwm.state.index_table[42].space)
        assert.are.equal(2, tiled_spaces[#tiled_spaces])
    end)

    it("reconciles a Mission Control transfer even without sampled bounds movement", function()
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDragged end,
            location = function() return { x = 120, y = 40 } end })
        assert.is_nil(Events.draggedWindowID(1))
        active_space = 2
        paperwm.windows.reconcileWindowSpace = function()
            paperwm.state.index_table[42].space = 2
            return 2, 1
        end
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseUp end })
        assert.are.equal(1, tile_calls)
        assert.are.equal(2, tiled_spaces[1])
    end)

    it("waits for an unassigned window before animating its release", function()
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseDown end })
        Events.windowEventHandler(window, "AXWindowMoved", paperwm)
        paperwm.windows.reconcileWindowSpace = function() return nil end
        button_tap({ getType = function() return hs.eventtap.event.types.leftMouseUp end })
        assert.are.equal(1, tile_calls)
        paperwm.windows.reconcileWindowSpace = function() return 1 end
        timers[#timers].callback()
        assert.are.equal(2, tile_calls)
    end)
end)
