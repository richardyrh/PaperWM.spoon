---@diagnostic disable

_G.hs = {
    eventtap = {
        event = {
            types = {
                gesture = 1,
            },
        },
    },
    math = {
        randomFromRange = function() return 123 end,
    },
}

describe("PaperWM.swipe", function()
    local Swipe = dofile("swipe.lua")

    describe("distanceTicks", function()
        it("retains travel until an interval is crossed", function()
            local remainder, ticks = Swipe.distanceTicks(0, 45, 120)
            assert.are.equal(45, remainder)
            assert.are.equal(0, ticks)

            remainder, ticks = Swipe.distanceTicks(remainder, 80, 120)
            assert.are.equal(5, remainder)
            assert.are.equal(1, ticks)
        end)

        it("counts absolute travel through direction changes", function()
            local remainder, ticks = Swipe.distanceTicks(90, -50, 120)
            assert.are.equal(20, remainder)
            assert.are.equal(1, ticks)
        end)

        it("reports every interval crossed by a fast sample", function()
            local remainder, ticks = Swipe.distanceTicks(20, 350, 120)
            assert.are.equal(10, remainder)
            assert.are.equal(3, ticks)
        end)

        it("disables and clears accumulation for nonpositive intervals", function()
            local remainder, ticks = Swipe.distanceTicks(60, 80, 0)
            assert.are.equal(0, remainder)
            assert.are.equal(0, ticks)
        end)
    end)

    describe("velocitySample", function()
        it("converges toward instantaneous movement velocity", function()
            local velocity = Swipe.velocitySample(0, 20, 0.02, 0.04)
            assert.is_true(velocity > 0)
            assert.is_true(velocity < 1000)
        end)

        it("changes direction immediately instead of coasting the wrong way", function()
            local velocity = Swipe.velocitySample(500, -20, 0.02, 0.04)
            assert.are.equal(-1000, velocity)
        end)
    end)

    describe("inertiaStep", function()
        it("integrates distance while exponentially reducing velocity", function()
            local distance, velocity = Swipe.inertiaStep(1000, 0.1, 5)
            assert.is_true(distance > 0)
            assert.is_true(distance < 100)
            assert.is_true(velocity > 0)
            assert.is_true(velocity < 1000)
        end)

        it("preserves constant velocity when friction is disabled", function()
            local distance, velocity = Swipe.inertiaStep(500, 0.1, 0)
            assert.are.equal(50, distance)
            assert.are.equal(500, velocity)
        end)
    end)

    describe("clampStripDelta", function()
        it("uses one delta for the strip and stops at either content edge", function()
            assert.are.equal(200, Swipe.clampStripDelta(300, -200, 1400, 0, 1000))
            assert.are.equal(-400, Swipe.clampStripDelta(-500, -200, 1400, 0, 1000))
        end)

        it("does not scroll content narrower than the viewport", function()
            assert.are.equal(0, Swipe.clampStripDelta(100, 100, 900, 0, 1000))
            assert.are.equal(0, Swipe.clampStripDelta(-100, 100, 900, 0, 1000))
        end)
    end)

    describe("directionLock", function()
        it("waits for enough travel before selecting an axis", function()
            assert.is_nil(Swipe.directionLock(5, 3, 12))
            assert.is_true(Swipe.directionLock(15, 4, 12))
            assert.is_false(Swipe.directionLock(4, 15, 12))
        end)
    end)

    describe("gesture lifecycle", function()
        it("ends on an empty fast lift and on full ended touch phases", function()
            local tap_callback
            hs.eventtap.new = function(_, callback)
                tap_callback = callback
                return { start = function() end, stop = function() end }
            end

            local calls = {}
            Swipe:start(3, function(_, kind) table.insert(calls, kind) end)
            local function touch(id, phase)
                return {
                    identity = id,
                    normalizedPosition = { x = 0, y = 0 },
                    phase = phase,
                }
            end
            local function event(touches)
                return {
                    getType = function() return 1 end,
                    getTouches = function() return touches end,
                    timestamp = function() return 1 end,
                }
            end

            tap_callback(event({
                touch(1, "began"), touch(2, "began"), touch(3, "began"),
            }))
            tap_callback(event({}))
            assert.are.same({ Swipe.BEGIN, Swipe.END }, calls)

            tap_callback(event({
                touch(4, "began"), touch(5, "began"), touch(6, "began"),
            }))
            tap_callback(event({
                touch(4, "ended"), touch(5, "ended"), touch(6, "ended"),
            }))
            assert.are.same({
                Swipe.BEGIN, Swipe.END, Swipe.BEGIN, Swipe.END,
            }, calls)
        end)
    end)
end)
