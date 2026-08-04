---@diagnostic disable

local native_bounds = {}
local native_transforms = {}
local native_capabilities = {}
local backend_probe_calls = 0
local native_move_calls = 0
local original_loadlib = package.loadlib

package.preload["windows"] = function()
    _G.hs = {
        spaces = {
            windowSpaces = function(_) return { 1 } end,
            focusedSpace = function() return 1 end,
            activeSpaces = function() return { mock_screen_uuid = 1 } end,
        },
        uielement = {
            watcher = {
                windowMoved = "windowMoved",
                windowResized = "windowResized",
            },
        },
        window = {
            animationDuration = 0.0,
            focusedWindow = function() return nil end,
        },
        geometry = {
            rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h, x2 = x + w, y2 = y + h } end,
        },
        fnutils = {
            partial = function(func, ...)
                local args = { ... }
                return function(...)
                    local all_args = {}
                    for i = 1, #args do all_args[i] = args[i] end
                    local arg_n = #args
                    local varargs = { ... }
                    for i = 1, #varargs do all_args[arg_n + i] = varargs[i] end
                    return func(table.unpack(all_args))
                end
            end,
        },
        screen = {
            mainScreen = function()
                return {
                    getUUID = function() return "mock_screen_uuid" end,
                    frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
                }
            end,
        },
        settings = {
            set = function(_, _) end,
        },
        spoons = {
            resourcePath = function(path) return "mock/" .. path end,
        },
        timer = {
            absoluteTime = function() return 0 end,
            secondsSinceEpoch = function() return 0 end,
        },
    }

    package.loadlib = function(path, symbol)
        if path == "mock/native/paperwm_transform.so" and
            symbol == "luaopen_paperwm_transform" then
            return function()
                return {
                    available = function() return true end,
                    backendProbe = function(ids)
                        backend_probe_calls = backend_probe_calls + 1
                        return {
                            checked = #ids > 0,
                            transform = native_capabilities.transform,
                            move = native_capabilities.move,
                            transform_mode = native_capabilities.transform_mode,
                            window_id = ids[1],
                            owner_connection = 2,
                            main_connection = 1,
                            transform_error = native_capabilities.transform_error,
                            move_error = native_capabilities.move_error,
                        }
                    end,
                    bounds = function(ids)
                        local frames = {}
                        for _, id in ipairs(ids) do
                            table.insert(frames, native_bounds[id])
                        end
                        return frames
                    end,
                    setAtomic = function(transforms)
                        native_transforms = transforms
                        return true
                    end,
                    move = function(moves)
                        native_move_calls = native_move_calls + 1
                        native_transforms = moves
                        return true
                    end,
                    set = function() return true end,
                    beginUpdates = function() return true end,
                    endUpdates = function() return true end,
                }
            end
        end
        return original_loadlib(path, symbol)
    end

    return dofile("windows.lua")
end

package.preload["state"] = function()
    return dofile("state.lua")
end

describe("PaperWM.windows", function()
    local Windows = require("windows")
    local State = require("state")

    local mock_screen = function()
        return {
            getUUID = function() return "mock_screen_uuid" end,
            frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
        }
    end

    -- Mock Hammerspoon objects and functions
    local mock_window = function(id, title, frame)
        frame = frame or { x = 0, y = 0, w = 100, h = 100 }
        frame.x2 = frame.x + frame.w
        frame.y2 = frame.y + frame.h
        frame.center = { x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 }
        return {
            id = function() return id end,
            title = function() return title end,
            frame = function() return frame end,
            application = function() return { bundleID = function() return "com.apple.Terminal" end } end,
            tabCount = function() return 0 end,
            isMaximizable = function() return true end,
            newWatcher = function()
                return {
                    start = function() end,
                    stop = function() end,
                }
            end,
            focus = function() end,
            setFrame = function(new_frame) frame = new_frame end,
            screen = function() return mock_screen() end,
        }
    end

    local mock_paperwm = {
        state = State,
        events = {
            windowEventHandler = function() end,
        },
        window_filter = {
            getWindows = function() return {} end,
        },
        animation_backend = "none",
        logger = {
            d = function(...) end,
            e = function(...) end,
            v = function(...) end,
            df = function(...) end,
            ef = function(...) end,
            wf = function(...) end,
        },
        tileSpace = function() end,
        window_gap = 8,
    }

    local focused_window

    before_each(function()
        -- Reset state before each test
        State.window_list = {}
        State.index_table = {}
        State.ui_watchers = {}
        State.is_floating = {}
        State.x_positions = {}
        mock_paperwm.animation_backend = "none"
        native_bounds = {}
        native_transforms = {}
        native_capabilities = {
            transform = true,
            move = true,
            transform_mode = "batch",
            transform_error = 0,
            move_error = 0,
        }
        backend_probe_calls = 0
        native_move_calls = 0
        hs.spaces.windowSpaces = function(_) return { 1 } end
        Windows.init(mock_paperwm)
        hs.window.focusedWindow = function() return focused_window end
    end)

    describe("beginInteractiveMove", function()
        it("caches denied foreign-window writes and starts on Accessibility", function()
            local win = mock_window(101, "Foreign")
            native_bounds[101] = { id = 101, x = 100, y = 0, w = 100, h = 100 }
            native_capabilities = {
                transform = false,
                move = false,
                transform_error = 1000,
                move_error = 1000,
            }
            mock_paperwm.animation_backend = "native"

            local first = Windows.beginInteractiveMove({ { window = win, x = 100 } })
            local second = Windows.beginInteractiveMove({ { window = win, x = 100 } })
            local status = Windows.nativeBackendStatus()

            assert.is_false(first)
            assert.is_false(second)
            assert.is_true(status.checked)
            assert.is_false(status.transform)
            assert.is_false(status.move)
            assert.are.equal(1, backend_probe_calls)
            assert.are.equal(0, native_move_calls)
        end)

        it("preserves virtual positions when resuming retained transforms", function()
            local win1 = mock_window(101, "Visible")
            local win2 = mock_window(102, "Distant")
            native_bounds[101] = { id = 101, x = 100, y = 0, w = 100, h = 100 }
            -- PaperWM parks distant real windows at the edge while retaining a
            -- distinct virtual position farther down the canvas.
            native_bounds[102] = { id = 102, x = 900, y = 0, w = 100, h = 100 }
            mock_paperwm.animation_backend = "native"

            local started = Windows.beginInteractiveMove({
                { window = win1, x = 100 },
                { window = win2, x = 1800 },
            })
            assert.is_true(started)

            local resumed = {
                { window = win1, x = 100 },
                { window = win2, x = 1800 },
            }
            local active = Windows.beginInteractiveMove(resumed)

            assert.is_true(active)
            assert.are.equal(100, resumed[1].frame.x)
            assert.are.equal(1800, resumed[2].frame.x)
            assert.are.equal(1800, resumed[2].x)

            assert.is_true(Windows.updateInteractiveMove(resumed))
            assert.are.equal(1800, native_transforms[2].x)
            Windows.endInteractiveMove()
        end)
    end)

    describe("addWindow", function()
        it("should add a window to the state", function()
            local win = mock_window(101, "Test Window")
            local space = Windows.addWindow(win)

            assert.are.equal(1, space)
            assert.are.equal(1, #State.window_list[space])
            assert.are.equal(1, #State.window_list[space][1])
            assert.are.equal(win, State.window_list[space][1][1])
            assert.is_not_nil(State.index_table[101])
            assert.are.equal(1, State.index_table[101].col)
            assert.are.equal(1, State.index_table[101].row)
            assert.is_not_nil(State.ui_watchers[101])
        end)

        it("returns the existing Space for duplicate visibility events", function()
            local win = mock_window(101, "Test Window")
            Windows.addWindow(win)

            assert.are.equal(1, Windows.addWindow(win))
            assert.are.equal(1, #State.window_list[1])
            assert.are.equal(1, #State.window_list[1][1])
        end)

        it("leaves a window untracked until it has a Space", function()
            local win = mock_window(101, "Test Window")
            hs.spaces.windowSpaces = function(_) return {} end

            assert.is_nil(Windows.addWindow(win))
            assert.is_nil(State.index_table[101])
            assert.is_nil(State.ui_watchers[101])
        end)
    end)


    describe("addWindowsInOrder", function()
        it("should add windows from left to right", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)

            assert.are.equal(win1, State.window_list[1][1][1])
            assert.are.equal(win2, State.window_list[1][2][1])
        end)
    end)

    describe("removeWindow", function()
        it("should remove a window from the state", function()
            local win = mock_window(101, "Test Window")
            Windows.addWindow(win)

            local space = Windows.removeWindow(win, true)

            assert.are.equal(1, space)
            assert.is_nil(State.window_list[space])
            assert.is_nil(State.index_table[101])
            assert.is_nil(State.ui_watchers[101])
        end)

        it("ignores removal of a window that was never tracked", function()
            local win = mock_window(101, "Transient Window")

            assert.is_nil(Windows.removeWindow(win, true))
            assert.is_nil(State.window_list[1])
        end)
    end)

    describe("swapWindows", function()
        it("should swap two windows horizontally", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            focused_window = win1

            Windows.swapWindows(Windows.Direction.RIGHT)

            assert.are.equal(win2, State.window_list[1][1][1])
            assert.are.equal(win1, State.window_list[1][2][1])
        end)

        it("should swap two windows vertically", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100, y2 = 100 })
            local win2 = mock_window(102, "Window 2", { x = 0, y = 108, w = 100, h = 100, y2 = 208 })
            Windows.addWindow(win1)
            -- manually add win2 to the same column
            table.insert(State.window_list[1][1], win2)
            State.index_table[102] = { space = 1, col = 1, row = 2 }
            focused_window = win1

            Windows.swapWindows(Windows.Direction.DOWN)

            assert.are.equal(win2, State.window_list[1][1][1])
            assert.are.equal(win1, State.window_list[1][1][2])
        end)
    end)

    describe("slurpWindow", function()
        it("should move the focused window into the column on the left", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            focused_window = win2

            Windows.slurpWindow()

            assert.are.equal(1, #State.window_list[1])    -- only one column left
            assert.are.equal(2, #State.window_list[1][1]) -- with two windows
            assert.are.equal(win1, State.window_list[1][1][1])
            assert.are.equal(win2, State.window_list[1][1][2])
        end)
    end)

    describe("barfWindow", function()
        it("should move the focused window to a new column on the right", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2")
            Windows.addWindow(win1)
            table.insert(State.window_list[1][1], win2)
            State.index_table[102] = { space = 1, col = 1, row = 2 }
            focused_window = win1

            Windows.barfWindow()

            assert.are.equal(2, #State.window_list[1])    -- two columns
            assert.are.equal(1, #State.window_list[1][1]) -- one window in first column
            assert.are.equal(1, #State.window_list[1][2]) -- one window in second column
            assert.are.equal(win2, State.window_list[1][1][1])
            assert.are.equal(win1, State.window_list[1][2][1])
        end)
    end)
end)
