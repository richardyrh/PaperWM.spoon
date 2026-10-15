describe("PaperWM configured Space numbers", function()
    local saved_hs, mc, assignments, layout, screens
    before_each(function()
        saved_hs = _G.hs
        assignments = {}
        layout = { A = { 11, 12 }, B = { 21 } }
        screens = { { getUUID = function() return "A" end }, { getUUID = function() return "B" end } }
        _G.hs = { application = {}, axuielement = {}, geometry = {}, mouse = {}, window = {},
            eventtap = { event = { types = {} } }, timer = {},
            logger = { new = function() return {} end },
            settings = { get = function(key)
                assert.are.equal("WarpMouse.spaceNumbers", key)
                return assignments
            end },
            screen = { allScreens = function() return screens end },
            spaces = { allSpaces = function() return layout end,
                spaceType = function() return "user" end },
        }
        mc = dofile("mission_control.lua")
    end)
    after_each(function() _G.hs = saved_hs end)

    it("preserves legacy numbering when nothing is assigned", function()
        assert.are.same({ 11, 12, 21 }, mc:getShortcutSpaceIDs())
    end)

    it("remaps shortcut targets without changing Mission Control thumbnail indexes", function()
        assignments = { A = { ["1"] = 3, ["2"] = 1 }, B = { ["1"] = 2 } }
        assert.are.same({ 12, 21, 11 }, mc:getShortcutSpaceIDs())
        assert.are.equal(21, mc:getSpaceID(2))
        assert.are.equal(3, mc:getSpaceIndex(21))
        assert.are.equal(1, mc:getSpaceIndex(11))
    end)

    it("survives screen enumeration changes and regenerated Space IDs", function()
        assignments = { A = { ["1"] = 3, ["2"] = 1 }, B = { ["1"] = 2 } }
        screens[1], screens[2] = screens[2], screens[1]
        layout = { A = { 101, 102 }, B = { 201 } }
        assert.are.same({ 102, 201, 101 }, mc:getShortcutSpaceIDs())
    end)

    it("does not let fullscreen Spaces shift saved desktop ordinals", function()
        layout.A = { 11, 99, 12 }
        hs.spaces.spaceType = function(id) return id == 99 and "fullscreen" or "user" end
        assignments = { A = { ["2"] = 1 } }
        assert.are.equal(12, mc:getSpaceID(1))
        assert.are.equal(3, mc:getSpaceIndex(12))
    end)

    it("reserves offline display numbers without stealing them for automatic desktops", function()
        assignments = { offline = { ["1"] = 1 } }
        assert.is_nil(mc:getSpaceID(1))
        assert.are.same({ [2] = 11, [3] = 12, [4] = 21 }, mc:getShortcutSpaceIDs())
    end)

    it("handles missing display lists and malformed persisted settings", function()
        layout.B, assignments = nil, false
        assert.are.same({ 11, 12 }, mc:getShortcutSpaceIDs())
        assert.is_nil(mc:getSpaceIndex(21))
    end)

    it("cycles sparse shortcut numbers rather than treating them as physical indexes", function()
        assignments = { A = { ["1"] = 7, ["2"] = 1 }, B = { ["1"] = 3 } }
        hs.spaces.focusedSpace = function() return 21 end
        hs.fnutils = {}
        local Space = dofile("space.lua")
        Space.MissionControl = mc
        Space.PaperWM = { windows = { Direction = { LEFT = -1, RIGHT = 1 } } }
        local switched
        Space.switchToSpace = function(number) switched = number end
        Space.incrementSpace(1)
        assert.are.equal(7, switched)
        Space.incrementSpace(-1)
        assert.are.equal(1, switched)
    end)
end)
