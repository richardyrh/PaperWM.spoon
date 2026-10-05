---@diagnostic disable

describe("PaperWM monitor gaps and layout transfers", function()
    local saved_hs, saved_dofile, Windows, paperwm, screens, settings, tiled
    local locations, frames, windows
    local function rect(x, y, w, h)
        return setmetatable({ x = x, y = y, w = w, h = h }, {
            __index = function(r, k)
                if k == "x2" then return r.x + r.w end
                if k == "y2" then return r.y + r.h end
                if k == "center" then return { x = r.x + r.w / 2, y = r.y + r.h / 2 } end
            end,
            __newindex = function(r, k, v)
                if k == "x2" then r.w = v - r.x
                elseif k == "y2" then r.h = v - r.y
                else rawset(r, k, v) end
            end,
        })
    end
    before_each(function()
        saved_hs, saved_dofile = _G.hs, _G.dofile
        settings, tiled, locations, frames, windows = {}, {}, { 1 }, {}, {}
        screens = {}
        for i = 1, 2 do
            screens[i] = { getUUID = function() return "monitor" .. i end,
                frame = function() return rect((i - 1) * 1000, 24, 1000, 800) end }
        end
        _G.hs = {
            window = { focusedWindow = function()
                return { screen = function() return screens[1] end }
            end, timeout = function() end },
            screen = { mainScreen = function() return screens[1] end },
            spaces = { windowSpaces = function() return locations end,
                spaceType = function() return "user" end,
                screensHaveSeparateSpaces = function() return true end,
                activeSpaceOnScreen = function(screen)
                    return screen == screens[1] and 1 or 2
                end },
            mouse = { getCurrentScreen = function() return screens[2] end },
            uielement = { watcher = {} }, timer = {},
            geometry = { rect = rect },
            settings = { get = function(key) return settings[key] end,
                set = function(key, value) settings[key] = value end },
            logger = { new = function() return {} end },
            spoons = { resourcePath = function(path) return path end },
        }
        Windows = saved_dofile("windows.lua")
        _G.dofile = function(path)
            if path == "config.lua" then return { gaps_enabled = true,
                gaps_by_screen = {}, window_gap = { left = 8, right = 8, top = 0, bottom = 8 },
                window_filter = { getWindows = function() return {} end } } end
            if path == "windows.lua" then return Windows end
            if path == "state.lua" then return saved_dofile(path) end
            return { init = function() end, start = function() end,
                retileSpace = function(space, canvas) tiled[#tiled + 1] = { space, canvas } end }
        end
        paperwm = saved_dofile("init.lua")
        _G.dofile = saved_dofile
        Windows.flushNativeAnimationBatch = function() return true end
        Windows.getWindowFrame = function(window)
            local f = frames[window:id()] or rect(0, 24, 200, 800)
            return rect(f.x, f.y, f.w, f.h)
        end
        for i = 1, 3 do windows[i] = { id = function() return i end } end
    end)
    after_each(function() _G.hs, _G.dofile = saved_hs, saved_dofile end)

    it("resolves gaps independently by stable monitor UUID", function()
        paperwm.gaps_by_screen.monitor1 = false
        assert.are.equal(0, Windows.getGap("bottom", screens[1]))
        assert.are.equal(8, Windows.getGap("bottom", screens[2]))
        assert.are.equal(0, Windows.getGap("top", screens[2]))
        assert.are.equal(800, Windows.getCanvas(screens[1]).h)
        assert.are.equal(792, Windows.getCanvas(screens[2]).h)
        paperwm.gaps_enabled = false
        paperwm.gaps_by_screen.monitor2 = true
        assert.are.equal(8, Windows.getGap("left", screens[2]))
    end)

    it("persists a toggle and reflows only the target monitor", function()
        assert.is_false(paperwm:toggleGaps(screens[2]))
        assert.is_nil(paperwm.gaps_by_screen.monitor1)
        assert.is_false(settings.PaperWM_gaps_by_screen.monitor2)
        assert.are.equal(1, #tiled)
        assert.are.equal(2, tiled[1][1])
        assert.are.equal(984, tiled[1][2].w)
        assert.are.equal(1000, Windows.getCanvas(screens[2]).w)
    end)

    it("restores saved monitor toggles at startup", function()
        settings.PaperWM_gaps_by_screen = { monitor1 = false, monitor2 = true }
        Windows.persistFloatingList = function() end
        Windows.refreshWindows = function() end
        Windows.stopAnimations = function() end
        paperwm:start()
        assert.is_false(Windows.gapsEnabled(screens[1]))
        assert.is_true(Windows.gapsEnabled(screens[2]))
    end)

    it("writes each row once using its final height", function()
        local moves = {}
        Windows.moveWindow = function(window, frame) moves[window:id()] =
            { count = ((moves[window:id()] or {}).count or 0) + 1, h = frame.h, y = frame.y } end
        Windows.tileColumn({ windows[1], windows[2] },
            { screen = screens[2], x = 1008, y = 24, y2 = 816 }, 390, 200)
        assert.are.equal(1, moves[1].count)
        assert.are.equal(1, moves[2].count)
        assert.are.equal(390, moves[1].h)
        assert.are.equal(394, moves[2].h)
        assert.are.equal(422, moves[2].y)
    end)

    it("transfers a dropped window and retains its watcher and destination ordering", function()
        local state = paperwm.state
        state.window_list = { [1] = { { windows[1] }, { windows[2] } }, [2] = { { windows[3] } } }
        state.x_positions = { [1] = { [1] = 100, [2] = 400 }, [2] = { [3] = 1500 } }
        Windows.updateIndexTable(1, 1); Windows.updateIndexTable(2, 1)
        local watcher = {}
        state.ui_watchers[1] = watcher
        frames[1], frames[3] = rect(1100, 24, 200, 800), rect(1500, 24, 200, 800)
        locations = { 2 }
        local current, previous = Windows.reconcileWindowSpace(windows[1])
        assert.are.equal(2, current); assert.are.equal(1, previous)
        assert.are.equal(watcher, state.ui_watchers[1])
        assert.are.same({ space = 2, col = 1, row = 1 }, state.index_table[1])
        assert.are.equal(1, state.index_table[2].col)
        assert.are.equal(2, state.index_table[3].col)
        assert.is_nil(state.x_positions[1][1])
        assert.are.equal(1100, state.x_positions[2][1])
    end)

    it("ignores temporary and multiple Space assignments", function()
        paperwm.state.index_table[1] = { space = 1, col = 1, row = 1 }
        locations = {}
        assert.is_nil(Windows.reconcileWindowSpace(windows[1]))
        locations = { 1, 2 }
        assert.is_nil(Windows.reconcileWindowSpace(windows[1]))
    end)
end)
