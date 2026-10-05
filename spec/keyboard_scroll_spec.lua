---@diagnostic disable

describe("PaperWM keyboard strip scrolling", function()
    local saved_hs, saved_cleanup, Windows, paperwm, focused, windows, moves

    before_each(function()
        saved_hs = _G.hs
        saved_cleanup = _G.PaperWMNativeAnimationCleanup
        _G.PaperWMNativeAnimationCleanup = nil
        local screen = {
            frame = function()
                return { x = 0, x2 = 1000, w = 1000, y = 0, h = 800 }
            end,
        }
        _G.hs = {
            screen = setmetatable({}, { __call = function() return screen end }),
            spaces = { spaceDisplay = function() return "screen" end },
            timer = {},
            uielement = { watcher = {} },
            window = { focusedWindow = function() return focused end },
            geometry = { rect = function(frame) return frame end },
        }
        Windows = dofile("windows.lua")
        moves = {}
        windows = {}
        for id = 1, 3 do
            windows[id] = {
                id = function() return id end,
                frame = { x = (id - 1) * 1000, y = 0, w = 1000, h = 800 },
            }
        end
        focused = windows[1]
        paperwm = {
            screen_margin = 0,
            keyboard_scroll_step = 0.25,
            state = {
                index_table = { [1] = { space = 1 } },
                window_list = { [1] = { { windows[1] }, { windows[2] }, { windows[3] } } },
                x_positions = { [1] = { [1] = 0, [2] = 1000, [3] = 2000 } },
            },
        }
        Windows.PaperWM = paperwm
        Windows.getWindowFrame = function(window)
            local frame = window.frame
            return { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
        end
        Windows.moveWindow = function(window, frame)
            window.frame = frame
            moves[#moves + 1] = { id = window:id(), x = frame.x }
        end
    end)

    after_each(function()
        _G.hs = saved_hs
        _G.PaperWMNativeAnimationCleanup = saved_cleanup
    end)

    it("pans right without changing focus", function()
        Windows.scrollStrip(Windows.Direction.RIGHT)
        assert.are.equal(focused, windows[1])
        assert.are.same({ [1] = -250, [2] = 750, [3] = 1750 },
            paperwm.state.x_positions[1])
        assert.are.equal(3, #moves)
    end)

    it("keeps virtual offscreen positions and clamps at the strip edge", function()
        for _ = 1, 12 do Windows.scrollStrip(Windows.Direction.RIGHT) end
        assert.are.equal(-2000, paperwm.state.x_positions[1][1])
        assert.are.equal(0, paperwm.state.x_positions[1][3])
        local move_count = #moves
        Windows.scrollStrip(Windows.Direction.RIGHT)
        assert.are.equal(move_count, #moves)
        Windows.scrollStrip(Windows.Direction.LEFT)
        assert.are.equal(-1750, paperwm.state.x_positions[1][1])
    end)
end)
