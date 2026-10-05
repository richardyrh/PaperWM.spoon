---@diagnostic disable

describe("PaperWM native Space transfer", function()
    local saved_hs, Space, paperwm, focused, locations, pending
    local removed, added, tiled, focused_space, legacy_moves, native_calls, native_ok
    local secondary_screen, moved_position

    before_each(function()
        saved_hs = _G.hs
        pending, removed, added, tiled, legacy_moves, native_calls = {}, 0, 0, {}, 0, 0
        focused_space, locations, native_ok = nil, { 1 }, true
        local screen = {
            getUUID = function() return "screen" end,
            frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
        }
        secondary_screen = {
            getUUID = function() return "secondary" end,
            frame = function()
                return { x = 2000, y = 0, w = 1000, h = 800 }
            end,
        }
        moved_position = nil
        focused = {
            id = function() return 42 end,
            screen = function() return screen end,
        }
        _G.hs = {
            screen = setmetatable({
                allScreens = function() return { screen } end,
                find = function(value) return value end,
            }, { __call = function(_, uuid)
                if uuid == "secondary" then return secondary_screen end
                return screen
            end }),
            spaces = {
                windowSpaces = function() return locations end,
                spaceType = function() return "user" end,
                spaceDisplay = function() return "screen" end,
            },
            host = { operatingSystemVersion = function() return { major = 27 } end },
            timer = {
                doAfter = function(_, callback)
                    pending[#pending + 1] = callback
                    return { stop = function() end }
                end,
            },
            window = { focusedWindow = function() return focused end },
            fnutils = {
                imap = function(items, func)
                    local result = {}
                    for i, item in ipairs(items) do result[i] = func(item) end
                    return result
                end,
                contains = function(items, target)
                    for _, item in ipairs(items) do
                        if item == target then return true end
                    end
                    return false
                end,
            },
            spoons = { resourcePath = function(path) return path end },
            logger = { new = function() return { ef = function() end } end },
            eventtap = { event = { types = {} } },
            geometry = {}, mouse = {}, application = {}, axuielement = {},
        }
        Space = dofile("space.lua")
        paperwm = {
            logger = { d = function() end, e = function() end,
                ef = function() end },
            state = { index_table = { [42] = { space = 1 } } },
            window_filter = { getFilters = function()
                return { override = {} }
            end },
            windows = {
                stopAnimations = function() end,
                nativeMoveWindowToSpace = function()
                    native_calls = native_calls + 1
                    return native_ok, native_ok and nil or "payload unavailable"
                end,
                nativeMoveWindowPosition = function(_, x, y)
                    moved_position = { x = x, y = y }
                    return true
                end,
                getWindowFrame = function()
                    return { x = 100, y = 30, w = 800, h = 700 }
                end,
                removeWindow = function()
                    removed = removed + 1
                    paperwm.state.index_table[42] = nil
                    return 1
                end,
                addWindow = function()
                    added = added + 1
                    paperwm.state.index_table[42] = { space = 2 }
                    return 2
                end,
            },
        }
        Space.init(paperwm)
        Space.tileSpace = function(space) tiled[#tiled + 1] = space end
        Space.MissionControl.getSpaceID = function(_, index) return index end
        Space.MissionControl.focusSpace = function(_, space)
            focused_space = space
        end
        Space.MissionControl.moveWindowToSpace = function()
            legacy_moves = legacy_moves + 1
            return true
        end
    end)

    after_each(function() _G.hs = saved_hs end)

    it("does not remove a window before the Dock move is verified", function()
        Space.moveWindowToSpace(2)
        assert.are.equal(0, removed)
        assert.are.equal(1, #pending)
        locations = { 2 }
        pending[1]()
        assert.are.equal(1, removed)
        assert.are.equal(1, added)
        assert.are.same({ 1, 2 }, tiled)
        assert.are.equal(2, focused_space)
        assert.are.equal(0, legacy_moves)
    end)

    it("leaves tiling untouched when the payload is missing on macOS 27", function()
        native_ok = false
        Space.moveWindowToSpace(2)
        assert.are.equal(0, removed)
        assert.are.equal(0, added)
        assert.are.equal(0, legacy_moves)
        assert.are.equal(0, #pending)
    end)

    it("preserves the Mission Control route on macOS 26", function()
        hs.host.operatingSystemVersion = function() return { major = 26 } end
        Space.moveWindowToSpace(2)
        assert.are.equal(0, native_calls)
        assert.are.equal(1, legacy_moves)
    end)

    it("relocates pixels when the target Space is on another display", function()
        hs.spaces.spaceDisplay = function(space)
            return space == 2 and "secondary" or "screen"
        end
        hs.screen.allScreens = function()
            return { focused:screen(), secondary_screen }
        end
        Space.moveWindowToSpace(2)
        locations = { 2 }
        pending[1]()
        assert.are.same({ x = 2100, y = 30 }, moved_position)
        assert.are.equal(1, added)
    end)
end)
