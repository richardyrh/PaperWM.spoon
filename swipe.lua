local Swipe   = {}
Swipe.__index = Swipe


-- swipe types
Swipe.BEGIN = 1
Swipe.MOVED = 2
Swipe.END   = 3

---consume horizontal travel and report each crossed distance threshold
---@param remainder number distance retained from prior samples
---@param delta number signed distance in the current sample
---@param interval number distance between thresholds
---@return number remainder
---@return number ticks
function Swipe.distanceTicks(remainder, delta, interval)
    if type(interval) ~= "number" or interval <= 0 then return 0, 0 end

    local distance = math.max(0, tonumber(remainder) or 0) +
        math.abs(tonumber(delta) or 0)
    local ticks = math.floor(distance / interval)
    return distance - (ticks * interval), ticks
end

---low-pass one movement sample into a frame-rate-independent velocity
---@param previous number prior velocity in pixels per second
---@param delta number movement in pixels
---@param elapsed number sample interval in seconds
---@param response number filter response time in seconds
---@return number velocity
function Swipe.velocitySample(previous, delta, elapsed, response)
    if type(elapsed) ~= "number" or elapsed <= 0 or elapsed > 0.2 then
        return tonumber(previous) or 0
    end

    local instantaneous = (tonumber(delta) or 0) / elapsed
    previous = tonumber(previous) or 0
    if previous ~= 0 and instantaneous * previous < 0 then
        return instantaneous
    end

    response = math.max(0.001, tonumber(response) or 0.04)
    local weight = 1 - math.exp(-elapsed / response)
    return previous + ((instantaneous - previous) * weight)
end

---integrate one exponentially decaying inertia interval
---@param velocity number current velocity in pixels per second
---@param elapsed number interval in seconds
---@param friction number exponential decay per second
---@return number distance
---@return number velocity
function Swipe.inertiaStep(velocity, elapsed, friction)
    velocity = tonumber(velocity) or 0
    elapsed = math.max(0, tonumber(elapsed) or 0)
    friction = math.max(0, tonumber(friction) or 0)
    if friction == 0 then return velocity * elapsed, velocity end

    local decay = math.exp(-friction * elapsed)
    return velocity * (1 - decay) / friction, velocity * decay
end

---clamp one shared strip delta at the scrollable content boundaries
---@param delta number requested movement
---@param content_left number current left edge of all content
---@param content_right number current right edge of all content
---@param viewport_left number allowed left boundary
---@param viewport_right number allowed right boundary
---@return number delta
function Swipe.clampStripDelta(delta, content_left, content_right,
        viewport_left, viewport_right)
    delta = tonumber(delta) or 0
    if content_right - content_left <= viewport_right - viewport_left then return 0 end
    if delta > 0 then
        return math.max(0, math.min(delta, viewport_left - content_left))
    elseif delta < 0 then
        return math.min(0, math.max(delta, viewport_right - content_right))
    end
    return 0
end


local Cache = { id = nil, direction = nil, distance = 0, size = 0, touches = {} }

function Cache:clear()
    self.id = nil
    self.direction = nil
    self.distance = 0
    self.size = 0
    self.touches = {}
end

function Cache:none(touches)
    local absent = true
    for _, touch in ipairs(touches) do
        absent = absent and (self.touches[touch.identity] == nil)
    end
    return absent
end

function Cache:all(touches)
    local present = true
    for _, touch in ipairs(touches) do
        present = present and (self.touches[touch.identity] ~= nil)
    end
    return present
end

function Cache:any(touches)
    for _, touch in ipairs(touches) do
        if self.touches[touch.identity] then return true end
    end
    return false
end

function Cache:set(touches)
    self:clear()
    for i, touch in ipairs(touches) do
        self.touches[touch.identity] = {
            x = touch.normalizedPosition.x,
            y = touch.normalizedPosition.y,
            dx = 0,
            dy = 0,
        }
        self.size = i
    end
    self.id = hs.math.randomFromRange(1, 0xFFFF)
    return self.id
end

function Cache:detect(touches)
    local moved = false
    local delta = { dx = 0, dy = 0 }
    local size = 0
    for i, touch in ipairs(touches) do
        local id = touch.identity
        local x, y = touch.normalizedPosition.x, touch.normalizedPosition.y
        local dx, dy = x - assert(self.touches[id]).x, y - assert(self.touches[id]).y

        -- Gesture events commonly mark only the finger that changed as moved;
        -- stationary fingers still belong to the gesture. Requiring every
        -- finger to move discarded samples while advancing the cache.
        moved = moved or (touch.phase == "moved")
        delta = { dx = delta.dx + dx, dy = delta.dy + dy }
        self.touches[id] = { x = x, y = y, dx = dx, dy = dy }
        size = i
    end

    assert(self.size == size)
    delta = { dx = delta.dx / size, dy = delta.dy / size }

    return moved, delta, self.id
end

-- fingers: number of fingers for swipe (must be at least 2)
-- callback: function(type, distance, id) end
--           id is a unique id across callbacks for the same swipe
--           type is Swipe.type { BEGIN, MOVED, END}
--           dx change in horizontal position between 0.0 and 1.0
--           dy change in vertical position between 0.0 and 1.0
local gesture <const> = hs.eventtap.event.types.gesture
function Swipe:start(fingers, callback)
    assert(fingers > 1)
    assert(callback)

    self.watcher = hs.eventtap.new({ gesture }, function(event)
        local type = event:getType(true)
        if type ~= gesture then return end
        local touches = event:getTouches()
        if self.trace then
            local phases = {}
            for _, touch in ipairs(touches) do
                table.insert(phases, string.format("%s:%s",
                    tostring(touch.identity), tostring(touch.phase)))
            end
            self.trace("raw touches=%d phases=%s event_ts=%s",
                #touches, table.concat(phases, ","), tostring(event:timestamp()))
        end

        local terminal_phase = false
        for _, touch in ipairs(touches) do
            if touch.phase == "ended" or touch.phase == "cancelled" then
                terminal_phase = true
                break
            end
        end

        -- A fast lift can report either no touches or the full set with an
        -- ended phase. The previous overlap-only check missed both cases and
        -- left the gesture without an END callback or release velocity.
        if Cache.id and (#touches ~= fingers or not Cache:all(touches) or
                terminal_phase) then
            callback(Cache.id, Swipe.END, 0, 0, event:timestamp())
            Cache:clear()
        end

        if terminal_phase then return end
        if not Cache.id and #touches == fingers then
            callback(Cache:set(touches), Swipe.BEGIN, 0, 0, event:timestamp())
        elseif Cache.id and Cache:all(touches) then
            local moved, delta, id = Cache:detect(touches)
            if moved then
                callback(id, Swipe.MOVED, delta.dx, delta.dy, event:timestamp())
            end
        end
    end)

    Cache:clear()
    self.watcher:start()
end

function Swipe:stop()
    if self.watcher then
        self.watcher:stop()
        self.watcher = nil
    end
end

return Swipe
