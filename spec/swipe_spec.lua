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
    timer = {},
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

        it("waits for clear axis dominance when a ratio is configured", function()
            assert.is_nil(Swipe.directionLock(0.02, 0.018, 0.01, 1.5))
            assert.is_true(Swipe.directionLock(0.03, 0.01, 0.01, 1.5))
            assert.is_false(Swipe.directionLock(0.01, 0.03, 0.01, 1.5))
        end)
    end)

    describe("snapTarget", function()
        local function item(id, col, x, width, row)
            return { id = id, col = col, row = row or 1, x = x, w = width }
        end

        it("keeps the current window after a small move offscreen", function()
            local target = Swipe.snapTarget({
                item(1, 1, -20, 1000), item(2, 2, 990, 1000),
            }, 1, -20, 0, 1000)
            assert.are.equal(1, target.id)
        end)

        it("changes only after the destination is more visible", function()
            local target, anchor_visible, target_visible = Swipe.snapTarget({
                item(1, 1, -600, 1000), item(2, 2, 410, 1000),
            }, 1, -600, 0, 1000)
            assert.are.equal(2, target.id)
            assert.is_true(target_visible > anchor_visible)
        end)

        it("keeps exact ties on the starting window", function()
            local target = Swipe.snapTarget({
                item(1, 1, -505, 1000), item(2, 2, 505, 1000),
            }, 1, -505, 0, 1000)
            assert.are.equal(1, target.id)
        end)

        it("compares proportions instead of pixel counts for unequal widths", function()
            local target = Swipe.snapTarget({
                item(1, 1, -500, 1000), item(2, 2, 510, 400),
            }, 1, -500, 0, 1000)
            assert.are.equal(2, target.id)
        end)

        it("supports positive and negative display origins and both directions", function()
            for _, left in ipairs({ -2000, 2000 }) do
                local target = Swipe.snapTarget({
                    item(1, 1, left - 410, 1000), item(2, 2, left + 600, 1000),
                }, 2, 600, left, left + 1000)
                assert.are.equal(1, target.id)
            end
        end)

        it("ignores hidden virtual columns and candidates behind the movement", function()
            local target = Swipe.snapTarget({
                item(1, 1, 0, 100), item(2, 2, -600, 1000),
                item(3, 3, 410, 1000), item(4, 4, 1420, 1000),
            }, 2, -600, 0, 1000)
            assert.are.equal(3, target.id)
        end)

        it("chooses the nearest winning column and preserves the row where possible", function()
            local target = Swipe.snapTarget({
                item(1, 1, -900, 1000, 2), item(2, 2, 110, 300, 1),
                item(3, 2, 110, 300, 2), item(4, 3, 420, 300, 1),
            }, 1, -900, 0, 1000)
            assert.are.equal(3, target.id)
        end)
    end)

    describe("coherentMotion", function()
        it("rejects a single moving contact and opposite finger movement", function()
            assert.is_false(Swipe.coherentMotion({ 0.04, 0, 0 }, 0.5))
            assert.is_false(Swipe.coherentMotion({ 0.04, -0.04, 0 }, 0.5))
        end)

        it("accepts coordinated fingers even if one is stationary", function()
            assert.is_true(Swipe.coherentMotion({ 0.02, 0.018, 0 }, 0.5))
            assert.is_true(Swipe.coherentMotion({ -0.02, -0.018, 0 }, 0.5))
            assert.is_true(Swipe.coherentMotion({ 0.02, 0.019 }, 0.5))
        end)
    end)

    describe("gesture lifecycle", function()
        it("ignores resting contacts and tracks accumulated motion through stationary packets", function()
            local tap_callback
            hs.eventtap.new = function(_, callback)
                tap_callback = callback
                return { start = function() end, stop = function() end }
            end
            local calls = {}
            Swipe:start(3, function(_, kind, dx, _, _, info)
                table.insert(calls, { kind = kind, dx = dx, info = info })
            end)
            local function touch(id, x, phase, resting)
                return { identity = id, normalizedPosition = { x = x, y = 0.5 },
                    phase = phase, resting = resting, type = "indirect" }
            end
            local function send(touches)
                tap_callback({ getType = function() return 1 end,
                    getTouches = function() return touches end,
                    timestamp = function() return 1 end })
            end
            send({ touch(1, 0.2, "began"), touch(2, 0.3, "began"),
                touch(3, 0.4, "began", true) })
            assert.are.equal(0, #calls)
            send({ touch(1, 0.2, "began"), touch(2, 0.3, "began"),
                touch(3, 0.4, "began"), touch(4, 0.5, "stationary", true) })
            send({ touch(1, 0.23, "moved"), touch(2, 0.3, "stationary"),
                touch(3, 0.4, "stationary") })
            assert.is_false(calls[2].info.coherent_horizontal)
            send({ touch(1, 0.23, "stationary"), touch(2, 0.33, "moved"),
                touch(3, 0.4, "stationary") })
            assert.is_true(calls[3].info.coherent_horizontal)
            send({ touch(1, 0.23, "stationary"), touch(2, 0.33, "stationary", true),
                touch(3, 0.4, "stationary") })
            assert.are.equal(Swipe.END, calls[4].kind)
            assert.is_true(calls[4].info.cancelled)
            Swipe:stop()
        end)

        it("debounces empty packets and ends on a sustained empty lift", function()
            local tap_callback
            local pending_end
            hs.eventtap.new = function(_, callback)
                tap_callback = callback
                return { start = function() end, stop = function() end }
            end
            hs.timer.doAfter = function(_, callback)
                pending_end = {
                    stopped = false,
                    stop = function(self) self.stopped = true end,
                    fire = function(self)
                        if not self.stopped then callback() end
                    end,
                }
                return pending_end
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
            assert.are.same({ Swipe.BEGIN }, calls)
            local transient_empty = pending_end
            tap_callback(event({
                touch(1, "stationary"), touch(2, "stationary"),
                touch(3, "stationary"),
            }))
            assert.is_true(transient_empty.stopped)

            tap_callback(event({}))
            pending_end:fire()
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
