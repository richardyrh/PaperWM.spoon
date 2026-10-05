---@diagnostic disable

describe("PaperWM macOS 27 Mission Control Space focus", function()
    local saved_hs

    before_each(function()
        saved_hs = _G.hs
    end)

    after_each(function() _G.hs = saved_hs end)

    it("uses the WindowManager thumbnail's AXPress action", function()
        local pressed, opened = 0, 0
        local function thumbnail()
            return { performAction = function(_, action)
                assert.are.equal("AXPress", action)
                pressed = pressed + 1
                return true
            end }
        end
        local list = { AXIdentifier = "mc.spaces.list", thumbnail(), thumbnail() }
        local spaces = { AXIdentifier = "mc.spaces", list }
        local display = { AXIdentifier = "mc.display", spaces }
        local manager = {}
        local screen = { getUUID = function() return "screen" end }
        _G.hs = {
            application = {
                applicationsForBundleID = function(bundle)
                    assert.are.equal("com.apple.WindowManager", bundle)
                    return { manager }
                end,
            },
            axuielement = { applicationElement = function(app)
                assert.are.equal(manager, app)
                return { display }
            end },
            eventtap = { event = { types = {} } },
            geometry = {}, mouse = {}, window = {},
            host = { operatingSystemVersion = function() return { major = 27 } end },
            spaces = {
                MCwaitTime = 0,
                allSpaces = function() return { screen = { 1, 2 } } end,
                openMissionControl = function() opened = opened + 1 end,
            },
            screen = { allScreens = function() return { screen } end },
            timer = { secondsSinceEpoch = function() return 0 end },
            logger = { new = function() return { ef = function() end } end },
        }
        local MissionControl = dofile("mission_control.lua")
        assert.is_true(MissionControl:pressSpace(2))
        assert.are.equal(1, opened)
        assert.are.equal(1, pressed)
    end)
end)
