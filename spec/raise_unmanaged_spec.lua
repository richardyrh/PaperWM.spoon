---@diagnostic disable

describe("PaperWM raising unmanaged windows", function()
    local saved_hs, saved_cleanup, Windows, windows, raised, space, managed, focused

    local function window(id, spaces, role)
        local win = {
            id = function() return id end,
            role = function() return role or "AXWindow" end,
            spaces = spaces,
            raise = function() error("AXRaise alone must not be used") end,
            setFrame = function() error("must not change layout") end,
        }
        win.focus = function()
            raised[#raised + 1] = id
            focused = win
            return win
        end
        return win
    end

    before_each(function()
        saved_hs = _G.hs
        saved_cleanup = _G.PaperWMNativeAnimationCleanup
        _G.PaperWMNativeAnimationCleanup = nil
        windows, raised, managed = {}, {}, {}
        focused = nil
        space = 5
        _G.hs = {
            screen = {}, timer = {}, uielement = { watcher = {} },
            spaces = {
                focusedSpace = function() return space end,
                windowSpaces = function(win) return win.spaces end,
            },
            window = { orderedWindows = function() return windows end },
        }
        Windows = dofile("windows.lua")
        Windows.PaperWM = {
            state = { index_table = managed },
            logger = { df = function() end },
        }
    end)

    after_each(function()
        _G.hs = saved_hs
        _G.PaperWMNativeAnimationCleanup = saved_cleanup
    end)

    it("raises unmanaged windows back-to-front, leaving managed windows alone", function()
        managed[2] = { space = 5 }
        windows = { window(1, { 5 }), window(2, { 5 }), window(3, { 5 }) }
        assert.are.equal(2, Windows.raiseUnmanagedWindows())
        assert.are.same({ 3, 1 }, raised)
        assert.are.equal(windows[1], focused)
    end)

    it("excludes other monitors' Spaces and non-window accessibility elements", function()
        windows = {
            window(1, { 6 }), window(2, { 5 }, "AXUnknown"),
            window(3, nil), window(4, { 6, 5 }), window(nil, { 5 }),
        }
        assert.are.equal(1, Windows.raiseUnmanagedWindows())
        assert.are.same({ 4 }, raised)
    end)

    it("continues after a stale window or failed raise", function()
        local stale = window(2, { 5 })
        stale.id = function() error("window closed") end
        local failing = window(3, { 5 })
        failing.focus = function() error("focus failed") end
        windows = { window(1, { 5 }), stale, failing, window(4, { 5 }) }
        assert.are.equal(2, Windows.raiseUnmanagedWindows())
        assert.are.same({ 4, 1 }, raised)
    end)

    it("does nothing when there is no focused Space", function()
        space = nil
        windows = { window(1, { 5 }) }
        assert.are.equal(0, Windows.raiseUnmanagedWindows())
        assert.are.same({}, raised)
    end)
end)
