---@diagnostic disable

describe("PaperWM native resize handoff", function()
    local saved_hs, saved_loadlib, saved_cleanup, Windows
    local window, backing, target, ax_app, operations, transforms, animations
    local delayed, repeating, now, commits, resize_mode, position_fails
    local animation_cancels
    local animation_timers

    local function rect(x, y, w, h)
        if type(x) == "table" then x, y, w, h = x.x, x.y, x.w, x.h end
        return { x = x, y = y, w = w, h = h, x2 = x + w, y2 = y + h }
    end

    local function advance(seconds)
        local deadline = now + seconds
        while true do
            local next_timer
            for _, timer in ipairs(delayed) do
                if timer.active and timer.deadline <= deadline and
                    (not next_timer or timer.deadline < next_timer.deadline) then
                    next_timer = timer
                end
            end
            if not next_timer then break end
            now = next_timer.deadline
            next_timer.active = false
            next_timer.callback()
        end
        now = deadline
        for _, timer in ipairs(repeating) do
            if timer.active then timer.callback() end
        end
    end

    before_each(function()
        saved_hs, saved_loadlib = _G.hs, package.loadlib
        saved_cleanup = _G.PaperWMNativeAnimationCleanup
        _G.PaperWMNativeAnimationCleanup = nil
        operations, transforms, animations, delayed, repeating = {}, {}, {}, {}, {}
        now, commits, resize_mode, position_fails = 0, 0, "immediate", false
        animation_cancels = 0
        animation_timers = {}
        backing = rect(100, 24, 1200, 1050)
        target = rect(8, 24, 1186, 1042)
        ax_app = {
            enhanced = true,
            attributeValue = function(self) return self.enhanced end,
            setAttributeValue = function(self, attribute, value)
                assert.are.equal("AXEnhancedUserInterface", attribute)
                self.enhanced = value
                table.insert(operations, "enhanced:" .. tostring(value))
                return self
            end,
        }
        local function timer(callback)
            return { callback = callback,
                start = function(self) self.active = true; return self end,
                stop = function(self) self.active = false end }
        end
        _G.hs = {
            screen = {}, spaces = {}, uielement = { watcher = {} },
            geometry = { rect = rect }, window = { animationDuration = 0.5 },
            axuielement = { applicationElement = function() return ax_app end },
            spoons = { resourcePath = function(path) return path end },
            timer = {
                absoluteTime = function() return now * 1000000000 end,
                secondsSinceEpoch = function() return now end,
                doAfter = function(delay, callback)
                    local pending = timer(callback):start()
                    pending.deadline = now + delay
                    table.insert(delayed, pending)
                    return pending
                end,
                new = function(_, callback)
                    local pending = timer(callback)
                    table.insert(repeating, pending)
                    return pending
                end,
            },
        }
        local helper = {
            available = function() return true end,
            backendProbe = function()
                return { checked = true, transform = true, move = true,
                    animation = true, transform_backend = "dock" }
            end,
            bounds = function() return { { id = 1, x = backing.x, y = backing.y,
                w = backing.w, h = backing.h } } end,
            beginUpdates = function() table.insert(operations, "lock"); return true end,
            endUpdates = function() table.insert(operations, "unlock"); return true end,
            set = function(items)
                table.insert(operations, "transform")
                transforms[#transforms + 1] = items[1]
                return true
            end,
            setAtomic = function(items)
                table.insert(operations, "transform")
                transforms[#transforms + 1] = items[1]
                return true
            end,
            commit = function(moves)
                commits = commits + 1
                backing.x, backing.y = moves[1].x, moves[1].y
                return true
            end,
            animate = function(items)
                if #items == 0 then
                    animation_cancels = animation_cancels + 1
                    for _, timer in ipairs(animation_timers) do timer:stop() end
                    return true
                end
                animations[#animations + 1] = items[1]
                if items[1].auto_commit then
                    animation_timers[#animation_timers + 1] = hs.timer.doAfter(items[1].duration, function()
                        backing.x, backing.y = items[1].end_x, items[1].end_y
                    end)
                end
                return true
            end,
        }
        package.loadlib = function() return function() return helper end end
        window = {
            id = function() return 1 end,
            application = function() return {} end,
            frame = function() return rect(backing) end,
            _size = function() return { w = backing.w, h = backing.h } end,
            _setTopLeft = function(_, point)
                table.insert(operations, "position")
                if position_fails then return false end
                backing.x, backing.y = point.x, point.y
                return window
            end,
            _setSize = function(_, size)
                table.insert(operations, "size")
                assert.is_false(ax_app.enhanced == true)
                if resize_mode == "failed" then return false end
                if resize_mode == "immediate" or resize_mode == "clamped" then
                    backing.w, backing.h = size.w, size.h
                    if resize_mode == "clamped" then backing.w = size.w - 10 end
                elseif resize_mode == "width-only" then
                    backing.w = size.w
                elseif resize_mode == "height-only" then
                    backing.h = size.h
                end
                return window
            end,
        }
        local watcher = { stop = function() end, start = function() end }
        Windows = dofile("windows.lua")
        Windows.init({ animation_backend = "native", state = {
                ui_watchers = { [1] = watcher }, index_table = { [1] = {} } },
            logger = { e = error, v = function() end, df = function() end,
                ef = function() end, wf = function() end } })
    end)

    after_each(function()
        Windows.stopAnimations(true)
        _G.hs, package.loadlib = saved_hs, saved_loadlib
        _G.PaperWMNativeAnimationCleanup = saved_cleanup
    end)

    it("suppresses app-side animation until the inverse transform is installed", function()
        Windows.moveWindow(window, target)
        assert.are.same({ "lock", "enhanced:false", "position", "size",
            "transform", "enhanced:true", "unlock" }, operations)
        assert.is_true(ax_app.enhanced)
        assert.are.equal(1042, backing.h)
        assert.are.equal(1050 / 1042, transforms[1].sy)
        advance(0)
        assert.is_true(animations[1].auto_commit)
        assert.are.equal(1050 / 1042, animations[1].start_sy)
        assert.are.equal(1, animations[1].end_sy)
    end)

    it("routes service-backed AX resize preparation through one native call", function()
        local native_requests = {}
        local original_loadlib = package.loadlib
        package.loadlib = function(...)
            local loader = original_loadlib(...)
            return function()
                local helper = loader()
                helper.prepareResize = function(request)
                    native_requests[#native_requests + 1] = request
                    backing.x, backing.y = request.end_x, request.end_y
                    backing.w, backing.h = request.end_w, request.end_h
                    return { accepted_w = backing.w, accepted_h = backing.h,
                        concealed = true }
                end
                return helper
            end
        end
        -- The helper is loaded lazily, so opt in before the first move.
        Windows.PaperWM.resize_handoff_backend = "service"
        window.application = function()
            return { pid = function() return 123 end }
        end
        Windows.moveWindow(window, target)
        assert.are.equal(1, #native_requests)
        assert.is_true(native_requests[1].service)
        assert.are.equal(1186, native_requests[1].end_w)
        assert.are.equal(1042, native_requests[1].end_h)
        assert.are.equal(0, #operations)
        advance(0)
        assert.is_true(animations[1].auto_commit)
    end)

    it("submits a completed native layout without waiting for the next run-loop turn", function()
        Windows.moveWindow(window, target)
        assert.are.equal(0, #animations)
        assert.is_true(Windows.flushNativeAnimationBatch())
        assert.are.equal(1, #animations)
        advance(0)
        assert.are.equal(1, #animations)
        assert.is_false(Windows.flushNativeAnimationBatch())
    end)



    it("cancels an existing Dock animation before drag reflow takes its window", function()
        hs.spaces.spaceDisplay = function() return "display" end
        setmetatable(hs.screen, { __call = function()
            return { frame = function() return rect(0, 0, 1920, 1080) end }
        end })
        Windows.PaperWM.state.index_table[1].space = 3
        Windows.PaperWM.state.window_list = { [3] = { { window } } }
        Windows.moveWindow(window, rect(1920, 24, 1200, 1050))
        advance(0)
        assert.is_true(Windows.beginLiveReflow(3))
        assert.are.equal(1, animation_cancels)
        Windows.moveWindow(window, rect(500, 24, 1200, 1050))
        assert.is_true(Windows.endLiveReflow(true))
        Windows.finishLiveReflow(3)
        advance(0.6)
        assert.are.equal(1, #animations)
        assert.are.equal(500, backing.x)
        assert.are.equal(500, Windows.getWindowFrame(window).x)
    end)

    it("animates drag release before the final AX position reconciliation", function()
        local helper = package.loadlib()()
        helper.move = function(moves)
            backing.x, backing.y = moves[1].x, moves[1].y
            return true
        end
        hs.spaces.spaceDisplay = function() return "display" end
        setmetatable(hs.screen, { __call = function()
            return { frame = function() return rect(0, 0, 1920, 1080) end }
        end })
        Windows.PaperWM.state.index_table[1].space = 3
        Windows.PaperWM.state.window_list = { [3] = { { window } } }
        Windows.beginLiveReflow(3)
        Windows.moveWindow(window, rect(500, 24, 1200, 1050))
        assert.is_true(Windows.endLiveReflow(true))
        Windows.finishLiveReflow(3)
        Windows.moveWindow(window, rect(450, 24, 1200, 1050))
        Windows.flushNativeAnimationBatch()
        assert.are.equal(1, #animations)
        assert.is_false(animations[1].auto_commit)
        assert.are.equal(0, #operations)
        advance(0.6)
        assert.are.equal(450, backing.x)
        assert.are.equal(1, commits)
        assert.are.equal("position", operations[#operations - 1])
        Windows.moveWindow(window, rect(400, 24, 1200, 1050))
        Windows.flushNativeAnimationBatch()
        assert.is_true(animations[2].auto_commit)
    end)



    it("preserves an already disabled or unsupported accessibility setting", function()
        ax_app.enhanced = false
        Windows.moveWindow(window, target)
        assert.is_false(ax_app.enhanced)
        assert.are.same({ "lock", "position", "size", "transform", "unlock" }, operations)
    end)

    it("works when enhanced UI is not supported", function()
        ax_app.enhanced = nil
        Windows.moveWindow(window, target)
        assert.is_nil(ax_app.enhanced)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
    end)

    it("restores accessibility state and update locks when the move fails", function()
        position_fails = true
        Windows.moveWindow(window, target)
        assert.are.same({ "lock", "enhanced:false", "position",
            "enhanced:true", "unlock" }, operations)
        assert.is_true(ax_app.enhanced)
    end)

    it("restores accessibility state and the original position when resize fails", function()
        resize_mode = "failed"
        Windows.moveWindow(window, target)
        assert.is_true(ax_app.enhanced)
        assert.are.equal(100, backing.x)
        assert.are.equal("unlock", operations[#operations])
    end)

    it("does not discard the bottom gap when AX initially returns the old size", function()
        resize_mode = "pending"
        Windows.moveWindow(window, target)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
        advance(0)
        assert.is_false(animations[1].auto_commit)
        assert.are.equal(1042 / 1050, animations[1].end_sy)
        backing.w, backing.h = target.w, target.h
        advance(0.6)
        assert.are.equal(1, commits)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
    end)

    it("unsticks the bottom edge before animating and keeps the gap on later navigation", function()
        resize_mode = "width-only"
        local corrections = 0
        window.setFrameWithWorkarounds = function(_, frame, duration)
            corrections = corrections + 1
            assert.are.equal(0, duration)
            assert.is_false(ax_app.enhanced)
            assert.are.equal("size", operations[#operations])
            backing = rect(frame)
            return window
        end
        Windows.moveWindow(window, target)
        assert.are.equal(1, corrections)
        assert.are.equal(1042, backing.h)
        assert.is_true(ax_app.enhanced)
        advance(0)
        assert.is_true(animations[1].auto_commit)
        assert.are.equal(1050 / 1042, animations[1].start_sy)
        advance(0.6)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)

        local next_frame = rect(target)
        next_frame.x = 200
        Windows.moveWindow(window, next_frame)
        advance(0.6)
        assert.are.equal(1, corrections, "position-only navigation needs no correction")
        assert.are.equal(1042, backing.h)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
    end)

    it("corrects a sticky final readback before dropping GPU compensation", function()
        resize_mode = "pending"
        Windows.moveWindow(window, target)
        local corrections = 0
        window.setFrameWithWorkarounds = function(_, frame, duration)
            corrections = corrections + 1
            assert.are.equal(0, duration)
            assert.is_false(ax_app.enhanced)
            backing = rect(frame)
            return window
        end
        advance(0.6)
        assert.are.equal(1, corrections)
        assert.are.equal(1, commits)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
        assert.is_true(ax_app.enhanced)
    end)

    it("does not use the edge workaround for an explicit changed size constraint", function()
        resize_mode = "clamped"
        window.setFrameWithWorkarounds = function() error("unexpected edge workaround") end
        Windows.moveWindow(window, target)
        assert.are.equal(1176, Windows.getWindowFrame(window).w)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
        assert.are.same({ "lock", "enhanced:false", "position", "size",
            "transform", "enhanced:true", "unlock" }, operations)
    end)

    it("restores accessibility state and update locks if the workaround fails", function()
        resize_mode = "pending"
        window.setFrameWithWorkarounds = function() error("workaround failed") end
        Windows.moveWindow(window, target)
        assert.is_true(ax_app.enhanced)
        assert.are.equal("unlock", operations[#operations])
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
    end)

    it("keeps the GPU presentation while the final AX readback is still stale", function()
        resize_mode = "pending"
        Windows.moveWindow(window, target)
        advance(0.6)
        assert.are.equal(0, commits)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
        assert.is_true(ax_app.enhanced)
        backing.w, backing.h = target.w, target.h
        advance(0.1)
        assert.are.equal(1, commits)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
    end)

    for _, mode in ipairs({ "width-only", "height-only" }) do
        it("retains the destination when only one dimension catches up: " .. mode, function()
            resize_mode = mode
            Windows.moveWindow(window, target)
            assert.are.equal(1186, Windows.getWindowFrame(window).w)
            assert.are.equal(1042, Windows.getWindowFrame(window).h)
            advance(0.6)
            assert.are.equal(0, commits)
            assert.are.equal(1042, Windows.getWindowFrame(window).h)
            backing.w, backing.h = target.w, target.h
            advance(0.1)
            assert.are.equal(1, commits)
        end)
    end

    it("eventually accepts a persistent size constraint without leaving a stretch", function()
        resize_mode = "pending"
        Windows.moveWindow(window, target)
        advance(0.6)
        assert.are.equal(0, commits)
        advance(0.25)
        assert.are.equal(0, commits)
        advance(0.5)
        assert.are.equal(1, commits)
        assert.are.equal(1050, Windows.getWindowFrame(window).h)
        assert.is_true(ax_app.enhanced)
    end)

    it("still respects an explicit changed size imposed by the app", function()
        resize_mode = "clamped"
        Windows.moveWindow(window, target)
        assert.are.equal(1176, Windows.getWindowFrame(window).w)
        assert.are.equal(1042, Windows.getWindowFrame(window).h)
        advance(0)
        assert.is_true(animations[1].auto_commit)
    end)
end)
