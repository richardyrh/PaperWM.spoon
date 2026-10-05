---@diagnostic disable

describe("PaperWM keyboard focus prelayout", function()
    local saved_hs, saved_cleanup, Windows, old_window, new_window, layouts

    before_each(function()
        saved_hs = _G.hs
        saved_cleanup = _G.PaperWMNativeAnimationCleanup
        _G.PaperWMNativeAnimationCleanup = nil
        old_window = { id = function() return 1 end }
        new_window = {
            id = function() return 2 end,
            focus = function() return true end,
        }
        _G.hs = {
            screen = {}, spaces = {}, uielement = { watcher = {} },
            window = {
                animationDuration = 0.5,
                focusedWindow = function() return old_window end,
            },
            timer = {
                absoluteTime = function() return 1000000000 end,
                doAfter = function()
                    return { stop = function() end }
                end,
            },
        }
        Windows = dofile("windows.lua")
        layouts = {}
        Windows.init({
            animation_backend = "native",
            state = {
                index_table = {
                    [1] = { space = 7, col = 1, row = 1 },
                    [2] = { space = 7, col = 2, row = 1 },
                },
                window_list = { [7] = { { old_window }, { new_window } } },
            },
            space = { tileSpace = function(space, _, _, preferred)
                layouts[#layouts + 1] = { space = space, preferred = preferred }
            end },
            logger = { d = function() end, e = function() end },
        })
    end)

    after_each(function()
        _G.hs = saved_hs
        _G.PaperWMNativeAnimationCleanup = saved_cleanup
    end)

    it("starts layout from the shortcut target without waiting for windowFocused", function()
        local flushes = 0
        Windows.flushNativeAnimationBatch = function()
            flushes = flushes + 1
        end
        assert.are.equal(new_window, Windows.focusWindow(Windows.Direction.RIGHT))
        assert.are.same({ { space = 7, preferred = new_window } }, layouts)
        assert.are.equal(1, flushes)
        assert.is_true(Windows.keyboardLayoutAlreadyStarted(new_window))
        Windows.noteKeyboardFocusEvent(new_window)
        assert.is_true(Windows.keyboardLayoutAlreadyStarted(new_window))
        assert.is_false(Windows.keyboardLayoutAlreadyStarted(old_window))
    end)
end)
