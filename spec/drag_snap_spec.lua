---@diagnostic disable

describe("PaperWM live drag layout", function()
    local saved_hs, saved_loadlib, Space, Windows, raw_move_window
    local dragged_id, dragged_x, dragged_w, writes, move_batches
    local transform_batches, commit_batches
    local native_move_ok, bounds_calls, focused_lookups
    local screen_x, virtual_positions
    local dragged, neighbor, paperwm

    before_each(function()
        saved_hs = _G.hs
        saved_loadlib = package.loadlib
        dragged_id, dragged_x, writes, move_batches, native_move_ok =
            42, 200, {}, {}, true
        transform_batches, commit_batches = {}, {}
        dragged_w = 100
        screen_x, virtual_positions = 0, {}
        bounds_calls, focused_lookups = 0, 0
        dragged = { id = function() return 42 end }
        neighbor = { id = function() return 43 end }
        local screen = {
            frame = function()
                return { x = screen_x, y = 0, w = 1000, h = 800,
                    x2 = screen_x + 1000, y2 = 800 }
            end,
        }
        _G.hs = {
            screen = setmetatable({
                allScreens = function() return { screen } end,
            }, {
                __call = function() return screen end,
            }),
            spaces = {
                spaceType = function() return "user" end,
                spaceDisplay = function() return "screen" end,
                activeSpaceOnScreen = function() return 1 end,
            },
            window = { animationDuration = 0, focusedWindow = function()
                focused_lookups = focused_lookups + 1
                return dragged
            end },
            timer = {
                absoluteTime = function() return 0 end,
                doAfter = function() return { stop = function() end } end,
            },
            uielement = { watcher = {} },
            geometry = { rect = function(x, y, w, h)
                return { x = x, y = y, w = w, h = h }
            end },
            spoons = { resourcePath = function(path) return path end },
        }
        package.loadlib = function()
            return function()
                return { available = function() return true end,
                move = function(moves)
                    move_batches[#move_batches + 1] = moves
                    return native_move_ok, native_move_ok and nil or "move unavailable"
                end, setAtomic = function(transforms)
                    transform_batches[#transform_batches + 1] = transforms
                    return true
                end, commit = function(moves, identities)
                    commit_batches[#commit_batches + 1] = {
                        moves = moves, identities = identities,
                    }
                    return true
                end, bounds = function(ids)
                    bounds_calls = bounds_calls + 1
                    local frames = {}
                    for _, id in ipairs(ids) do
                        frames[#frames + 1] = {
                            id = id, x = id == 42 and dragged_x or 400,
                            y = id == 42 and 40 or 0,
                            w = id == 42 and dragged_w or 100,
                            h = id == 42 and 200 or 800,
                        }
                    end
                    return frames
                end }
            end
        end
        Windows = dofile("windows.lua")
        raw_move_window = Windows.moveWindow
        Space = dofile("space.lua")
        Windows.getWindowFrame = function(window)
            if window:id() == 42 then
                return { x = dragged_x, y = 40, w = dragged_w, h = 200,
                    x2 = dragged_x + dragged_w, y2 = 240 }
            end
            return { x = 400, y = 0, w = 100, h = 800,
                x2 = 500, y2 = 800 }
        end
        Windows.getGap = function() return 8 end
        Windows.getCanvas = function()
            return { x = screen_x, y = 0, w = 1000, h = 800,
                x2 = screen_x + 1000, y2 = 800 }
        end
        Windows.getColumn = function(space, col)
            return paperwm.state.window_list[space][col]
        end
        Windows.updateVirtualPositions = function(_, column, x)
            for _, window in ipairs(column) do virtual_positions[window:id()] = x end
        end
        Windows.moveWindow = function(window, frame)
            writes[#writes + 1] = { id = window:id(), x = frame.x }
        end
        paperwm = {
            state = {
                window_list = { [1] = { { dragged }, { neighbor } } },
                index_table = {
                    [42] = { space = 1, col = 1, row = 1 },
                    [43] = { space = 1, col = 2, row = 1 },
                },
                is_floating = {},
                ui_watchers = {
                    [42] = { stop = function() end, start = function() end },
                    [43] = { stop = function() end, start = function() end },
                },
            },
            events = { draggedWindowID = function() return dragged_id end },
            windows = Windows,
            animation_backend = "native",
            screen_margin = 0,
            logger = { e = function() end },
        }
        Space.PaperWM = paperwm
        Windows.PaperWM = paperwm
    end)

    after_each(function()
        _G.hs = saved_hs
        package.loadlib = saved_loadlib
    end)

    it("reflows neighbors without repositioning the pointer-controlled window", function()
        Space.tileSpace(1)
        assert.are.same({ { id = 43, x = 308 } }, writes)
        assert.are.equal(0, focused_lookups)

        dragged_id, writes = nil, {}
        Space.tileSpace(1)
        assert.are.equal(42, writes[1].id)
        assert.are.equal(43, writes[2].id)
        assert.are.equal(1, focused_lookups)
    end)

    it("uses the drag's cached display without repeating Space lookups", function()
        hs.spaces.spaceType = function() error("spaceType queried during drag") end
        hs.spaces.spaceDisplay = function() error("spaceDisplay queried during drag") end
        Space.tileSpace(1, nil, hs.screen())
        assert.are.same({ { id = 43, x = 308 } }, writes)
    end)

    it("tiles from a keyboard destination before AX focus catches up", function()
        dragged_id, writes = nil, {}
        Space.tileSpace(1, nil, nil, neighbor)
        assert.are.equal(0, focused_lookups)
        assert.are.same({ id = 43, x = 400 }, writes[1])
        assert.are.same({ id = 42, x = 292 }, writes[2])
    end)

    it("follows a dragged anchor but keeps an off-screen neighbor at the display edge", function()
        dragged_x, writes = -40, {}
        Space.tileSpace(1)
        assert.are.same({ { id = 43, x = 68 } }, writes)

        dragged_x, writes = 980, {}
        Space.tileSpace(1)
        assert.are.same({ { id = 43, x = 999 } }, writes)
        assert.are.equal(1088, virtual_positions[43])
    end)

    it("keeps one pixel on screen when a full-width window's gap reaches the edge", function()
        dragged_id, dragged_x, dragged_w = nil, 16, 968
        paperwm.screen_margin = 1
        Windows.getGap = function() return 16 end
        Windows.getCanvas = function()
            return { x = 16, y = 0, w = 968, h = 800,
                x2 = 984, y2 = 800 }
        end
        Space.tileSpace(1)
        assert.are.same({ { id = 42, x = 16 }, { id = 43, x = 999 } }, writes)

        paperwm.state.window_list[1] = { { neighbor }, { dragged } }
        paperwm.state.index_table[42].col = 2
        paperwm.state.index_table[43].col = 1
        writes = {}
        Space.tileSpace(1)
        assert.are.same({ { id = 42, x = 16 }, { id = 43, x = -99 } }, writes)
    end)

    it("clamps native reflow targets to the owning screen even at nonzero origins", function()
        hs.screen.allScreens = function() error("reflow must not enumerate other displays") end
        for _, origin in ipairs({ -1920, 1920 }) do
            screen_x, dragged_x = origin, origin + 980
            writes, move_batches = {}, {}
            Windows.moveWindow = raw_move_window
            Windows.beginLiveReflow(1)
            Space.tileSpace(1, nil, hs.screen())
            assert.is_true(Windows.endLiveReflow(true))
            assert.are.equal(origin + 999, move_batches[1][1].x)
            assert.are.equal(origin + 1088, virtual_positions[43])

            dragged_x = origin - 400
            move_batches = {}
            Windows.beginLiveReflow(1)
            Space.tileSpace(1, nil, hs.screen())
            Windows.endLiveReflow(true)
            assert.are.equal(origin - 99, move_batches[1][1].x)
        end
    end)


    it("does not let a regular layout write over an active drag", function()
        paperwm.state.ui_watchers[43].stop = function()
            error("ordinary layout must not take the drag's watcher")
        end
        raw_move_window(neighbor, { x = 308, y = 0, w = 100, h = 800 })
        assert.are.equal(0, #move_batches)
    end)

    it("mutes neighbor AX feedback for the drag and restores it on release", function()
        local stops, starts, callbacks = 0, 0, {}
        paperwm.state.ui_watchers[43] = {
            stop = function() stops = stops + 1 end,
            start = function() starts = starts + 1 end,
        }
        hs.timer.doAfter = function(_, callback)
            callbacks[#callbacks + 1] = callback
            return { stop = function() end }
        end
        for _ = 1, 2 do
            Windows.beginLiveReflow(1)
            raw_move_window(neighbor, { x = 308, y = 0, w = 100, h = 800 })
            Windows.endLiveReflow(true)
        end
        assert.are.equal(1, stops)
        assert.are.equal(0, starts)
        Windows.finishLiveReflow(1)
        for _, callback in ipairs(callbacks) do callback() end
        assert.are.equal(1, starts)
    end)

    it("keeps a released window partly off-screen until focus changes", function()
        dragged_id, dragged_x, dragged_w, writes = nil, -40, 300, {}
        Space.rememberDragRelease(1, 42)
        Space.tileSpace(1)
        assert.are.equal(-40, writes[1].x)
        assert.are.equal(268, writes[2].x)

        Space.clearDragReleaseOnFocus(1, 43)
        writes = {}
        Space.tileSpace(1)
        assert.are.equal(0, writes[1].x)
    end)

    it("coalesces live position writes into one native batch", function()
        assert.is_true(Windows.beginLiveReflow())
        raw_move_window(neighbor, { x = 308, y = 0, w = 100, h = 800 })
        raw_move_window(neighbor, { x = 320, y = 0, w = 100, h = 800 })
        raw_move_window(dragged, { x = 200, y = 40, w = 100, h = 200 })
        local native, count = Windows.endLiveReflow(true)
        assert.is_true(native)
        assert.are.equal(2, count)
        assert.are.equal(1, #move_batches)
        assert.are.same({
            { id = 43, x = 320, y = 0 },
            { id = 42, x = 200, y = 40 },
        }, move_batches[1])
    end)

    it("keeps the Accessibility reflow fallback if native moves fail", function()
        native_move_ok = false
        assert.is_true(Windows.beginLiveReflow())
        raw_move_window(neighbor, { x = 308, y = 0, w = 100, h = 800 })
        local native, count, reason = Windows.endLiveReflow(true)
        assert.is_false(native)
        assert.are.equal(1, count)
        assert.are.equal("move unavailable", reason)
        assert.are.same({ { id = 43, x = 308 } }, writes)
    end)

    it("uses one native bounds batch per live layout pass", function()
        assert.is_true(Windows.beginLiveReflow(1))
        assert.are.equal(200, Windows.getWindowFrame(dragged).x)
        assert.are.equal(400, Windows.getWindowFrame(neighbor).x)
        assert.are.equal(1, bounds_calls)
        Windows.endLiveReflow(false)
    end)

    it("forces an AX frame sync after a native live move", function()
        local target = { x = 308, y = 0, w = 100, h = 800 }
        local commits = 0
        paperwm.state.ui_watchers[43] = {
            stop = function() end, start = function() end,
        }
        neighbor.application = function() return nil end
        neighbor.setFrame = function(_, frame, duration)
            commits = commits + 1
            assert.are.equal(target, frame)
            assert.are.equal(0, duration)
        end
        Windows.beginLiveReflow()
        raw_move_window(neighbor, target)
        Windows.endLiveReflow(true)
        Windows.getWindowFrame = function() return target end
        dragged_id = nil
        raw_move_window(neighbor, target)
        assert.are.equal(1, commits)
    end)

    it("finds a managed drag target from native bounds without AX", function()
        local window, space, frame = Windows.managedWindowAtPoint(
            { x = 220, y = 60 })
        assert.are.equal(42, window:id())
        assert.are.equal(1, space)
        assert.are.equal(200, frame.x)
        assert.are.equal(1, bounds_calls)
    end)
end)
