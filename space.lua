local Screen <const> = hs.screen
local Spaces <const> = hs.spaces
local Fnutils <const> = hs.fnutils
local Timer <const> = hs.timer
local Window <const> = hs.window

local Space = {}
Space.__index = Space
local hud_update_timer = nil
local released_drag_anchors = {}

---retain a grab-able portion of a manually dragged window after mouse-up
function Space.rememberDragRelease(space, window_id)
    released_drag_anchors[space] = window_id
end

---normal focus navigation restores full on-screen anchor constraints
function Space.clearDragReleaseOnFocus(space, window_id)
    if released_drag_anchors[space] ~= window_id then
        released_drag_anchors[space] = nil
    end
end

local function scheduleHudUpdate()
    if hud_update_timer then hud_update_timer:stop() end
    hud_update_timer = Timer.doAfter(Window.animationDuration + 0.02, function()
        hud_update_timer = nil
        if Space.PaperWM.hud then Space.PaperWM.hud.update() end
    end)
end

---initialize module with reference to PaperWM
---@param paperwm PaperWM
function Space.init(paperwm)
    Space.PaperWM = paperwm
    Space.MissionControl = dofile(hs.spoons.resourcePath("mission_control.lua"))
    Space.MissionControl.PaperWM = paperwm  -- Pass PaperWM reference for config access
end

---tile all column in a space by moving and resizing windows
---@param space Space
---@param previous_canvas Frame|nil prior usable bounds when changing gap settings
---@param live_screen Screen|nil cached display for a verified live drag
---@param preferred_anchor Window|nil destination of immediate keyboard navigation
function Space.tileSpace(space, previous_canvas, live_screen, preferred_anchor)
    if not space or (not live_screen and Spaces.spaceType(space) ~= "user") then
        Space.PaperWM.logger.e("current space invalid")
        return
    end

    -- Removing the final managed window still schedules one last layout pass.
    -- An empty Space is therefore an expected no-op, not a missing anchor.
    local columns = Space.PaperWM.state.window_list[space]
    if not columns or #columns == 0 then return end

    -- find screen for space
    local screen = live_screen or Screen(Spaces.spaceDisplay(space))
    if not screen then
        Space.PaperWM.logger.e("no screen for space")
        return
    end

    local dragged_id = Space.PaperWM.events and
        Space.PaperWM.events.draggedWindowID and
        Space.PaperWM.events.draggedWindowID(space)
    local preferred_id = dragged_id or
        (preferred_anchor and preferred_anchor:id()) or released_drag_anchors[space]
    local preferred_index = preferred_id and Space.PaperWM.state.index_table[preferred_id]
    local preferred_column = preferred_index and preferred_index.space == space and
        columns[preferred_index.col]
    local preferred_window = preferred_column and preferred_column[preferred_index.row]

    -- if focused window is in space, tile from that. Use the cached index
    -- rather than Spaces.windowSpaces (a slow private-API call) because
    -- tileSpace runs on every throttled frame of a live drag/resize.
    local focused_window
    if not preferred_window then focused_window = Window.focusedWindow() end
    local anchor_window = (function()
        if preferred_window and preferred_window:id() == preferred_id then
            return preferred_window
        end
        local focused_index = focused_window and Space.PaperWM.state.index_table[focused_window:id()]
        if focused_window and not Space.PaperWM.state.is_floating[focused_window:id()] and
            focused_index and focused_index.space == space then
            return focused_window
        else
            return Space.PaperWM.windows.getFirstVisibleWindow(space, screen:frame())
        end
    end)()

    if not anchor_window then
        Space.PaperWM.logger.e("no anchor window in space")
        return
    end

    local anchor_index = Space.PaperWM.state.index_table[anchor_window:id()]
    if not anchor_index then
        Space.PaperWM.logger.e("anchor index not found, refreshing windows")
        Space.PaperWM.windows.refreshWindows() -- try refreshing the windows
        return                                 -- bail
    end

    -- During a physical drag, WindowServer's position is authoritative. Tile
    -- the neighbors from it, but do not clamp or write its pointer-controlled
    -- frame. On release, keep a small grab-able portion within the canvas.
    local dragging_anchor = dragged_id ~= nil and anchor_window:id() == dragged_id
    local released_anchor = released_drag_anchors[space] == anchor_window:id()
    local free_anchor = dragging_anchor or released_anchor

    -- get some global coordinates
    local screen_frame <const> = screen:frame()
    local edge_margin <const> = math.max(1, Space.PaperWM.screen_margin)
    local left_margin <const> = screen_frame.x + edge_margin
    local right_margin <const> = screen_frame.x2 - edge_margin
    local canvas <const> = Space.PaperWM.windows.getCanvas(screen)

    -- make sure anchor window is on screen
    local anchor_frame = Space.PaperWM.windows.getWindowFrame(anchor_window)
    if previous_canvas then
        local at_left = math.abs(anchor_frame.x - previous_canvas.x) <= 1
        local at_right = math.abs(anchor_frame.x2 - previous_canvas.x2) <= 1
        if math.abs(anchor_frame.w - previous_canvas.w) <= 1 then
            anchor_frame.w = canvas.w
        end
        if at_left then
            anchor_frame.x = canvas.x
        elseif at_right then
            anchor_frame.x = canvas.x2 - anchor_frame.w
        end
    end
    anchor_frame.w = math.min(anchor_frame.w, canvas.w)
    anchor_frame.h = math.min(anchor_frame.h, canvas.h)
    if released_anchor and not dragging_anchor then
        local visible_width = math.min(anchor_frame.w, 120)
        anchor_frame.x = math.max(anchor_frame.x,
            canvas.x + visible_width - anchor_frame.w)
        anchor_frame.x = math.min(anchor_frame.x,
            canvas.x2 - visible_width)
    elseif not dragging_anchor then
        anchor_frame.x = math.max(anchor_frame.x, canvas.x)
    end
    if not free_anchor and anchor_frame.x2 > canvas.x2 then
        anchor_frame.x = canvas.x2 - anchor_frame.w
    end

    -- adjust anchor window column
    local column = Space.PaperWM.windows.getColumn(space, anchor_index.col)
    if not column then
        Space.PaperWM.logger.e("no anchor window column")
        return
    end

    -- TODO: need a minimum window height
    if #column == 1 then
        anchor_frame.y, anchor_frame.h = canvas.y, canvas.h
        if anchor_window:id() ~= dragged_id then
            Space.PaperWM.windows.moveWindow(anchor_window, anchor_frame)
        end
    else
        local n = #column - 1 -- number of other windows in column
        local bottom_gap = Space.PaperWM.windows.getGap("bottom", screen)
        local h =
            math.max(0, canvas.h - anchor_frame.h - (n * bottom_gap)) // n
        local bounds = {
            screen = screen,
            x = anchor_frame.x,
            x2 = nil,
            y = canvas.y,
            y2 = canvas.y2,
        }
        Space.PaperWM.windows.tileColumn(column, bounds, h, anchor_frame.w, anchor_window:id(),
            anchor_frame.h, dragged_id)
    end
    Space.PaperWM.windows.updateVirtualPositions(space, column, anchor_frame.x)

    local right_gap = Space.PaperWM.windows.getGap("right", screen)
    local left_gap = Space.PaperWM.windows.getGap("left", screen)

    -- tile windows from anchor right
    local first_right_x = anchor_frame.x2 + right_gap
    local x = first_right_x
    for col = anchor_index.col + 1, #(Space.PaperWM.state.window_list[space] or {}) do
        local bounds = {
            screen = screen,
            -- Keep a strip on this display even during an unconstrained drag.
            -- x_positions below retains the unclamped logical strip position.
            x = math.min(x, right_margin),
            x2 = nil,
            min_x2 = left_margin,
            max_x = right_margin,
            y = canvas.y,
            y2 = canvas.y2,
        }
        local column = Space.PaperWM.windows.getColumn(space, col)
        local width = Space.PaperWM.windows.tileColumn(column, bounds,
            nil, nil, nil, nil, dragged_id)
        Space.PaperWM.windows.updateVirtualPositions(space, column, x)
        x = x + width + right_gap
    end

    -- tile windows from anchor left
    local first_left_x2 = anchor_frame.x - left_gap
    local x2 = first_left_x2
    for col = anchor_index.col - 1, 1, -1 do
        local bounds = {
            screen = screen,
            x = nil,
            x2 = math.max(x2, left_margin),
            min_x2 = left_margin,
            max_x = right_margin,
            y = canvas.y,
            y2 = canvas.y2,
        }
        local column = Space.PaperWM.windows.getColumn(space, col)
        local width = Space.PaperWM.windows.tileColumn(column, bounds,
            nil, nil, nil, nil, dragged_id)
        Space.PaperWM.windows.updateVirtualPositions(space, column, x2 - width)
        x2 = x2 - width - left_gap
    end

    if Space.PaperWM.hud then scheduleHudUpdate() end
end

---stop delayed work owned by the space module
function Space.stop()
    released_drag_anchors = {}
    if hud_update_timer then
        hud_update_timer:stop()
        hud_update_timer = nil
    end
end

---switch to a Mission Control space
---@param index number incremental id for space
function Space.switchToSpace(index)
    local space = Space.MissionControl:getSpaceID(index)
    if not space then
        Space.PaperWM.logger.d("space not found")
        return
    end

    local screen = Screen(Spaces.spaceDisplay(space))
    local window = Space.PaperWM.windows.getFirstVisibleWindow(space, screen:frame())
    Space.MissionControl:focusSpace(space, window)
end

---switch to a Mission Control space to the left or right of current space
---@param direction Direction use Direction.LEFT or Direction.RIGHT
function Space.incrementSpace(direction)
    if (direction ~= Space.PaperWM.windows.Direction.LEFT and direction ~= Space.PaperWM.windows.Direction.RIGHT) then
        Space.PaperWM.logger.d("move is invalid, left and right only")
        return
    end
    local curr_space_id = Spaces.focusedSpace()
    local numbered = Space.MissionControl:getShortcutSpaceIDs()
    local numbers = {}
    for number in pairs(numbered) do numbers[#numbers + 1] = number end
    table.sort(numbers)
    local curr_space_idx
    for idx, number in ipairs(numbers) do
        if numbered[number] == curr_space_id then curr_space_idx = idx; break end
    end

    if curr_space_idx then
        local new_space_idx = ((curr_space_idx - 1 + direction) % #numbers) + 1
        Space.switchToSpace(numbers[new_space_idx])
    end
end

---move focused window to a Mission Control space
---@param index number space index
function Space.moveWindowToSpace(index)
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Space.PaperWM.logger.d("focused window not found")
        return
    end

    -- Mission Control uses blocking waits, so animation timers cannot finish
    -- during its drag routine. Commit and clear presentation transforms first.
    Space.PaperWM.windows.stopAnimations()

    local new_space = Space.MissionControl:getSpaceID(index)
    if not new_space then
        Space.PaperWM.logger.d("space not found")
        return
    end

    local current_spaces = Spaces.windowSpaces(focused_window) or {}
    if new_space == current_spaces[1] then
        Space.PaperWM.logger.d("window already on space")
        return
    end

    if Spaces.spaceType(new_space) ~= "user" then
        Space.PaperWM.logger.d("space is invalid")
        return
    end

    local old_screen = focused_window:screen()
    if not old_screen then
        Space.PaperWM.logger.d("no screen for window")
        return
    end

    local new_screen = Screen(Spaces.spaceDisplay(new_space))
    if not new_screen then
        Space.PaperWM.logger.d("no screen for space")
        return
    end

    -- get list of screens allowed by the window filter as hs.screen objects
    local allowed_screens = Space.PaperWM.window_filter:getFilters().override.allowScreens or Screen.allScreens()
    allowed_screens = Fnutils.imap(allowed_screens, function(screen) return Screen.find(screen) end)

    local os_version = hs.host and hs.host.operatingSystemVersion()
    local needs_dock_move = os_version and os_version.major >= 27
    local native_moved, native_error = false, nil
    if needs_dock_move then
        native_moved, native_error =
            Space.PaperWM.windows.nativeMoveWindowToSpace(
                focused_window:id(), new_space)
    end
    if native_moved then
        local old_space = (Space.PaperWM.state.index_table[focused_window:id()] or {}).space or
            current_spaces[1]
        local function finishMove(attempt)
            local actual_spaces = Spaces.windowSpaces(focused_window) or {}
            if not Fnutils.contains(actual_spaces, new_space) then
                if attempt < 10 then
                    Timer.doAfter(0.05, function() finishMove(attempt + 1) end)
                else
                    Space.PaperWM.logger.ef(
                        "Dock did not move window %d to Space %d",
                        focused_window:id(), new_space)
                end
                return
            end
            if Space.PaperWM.state.index_table[focused_window:id()] then
                Space.PaperWM.windows.removeWindow(focused_window, true)
            end
            if old_space then Space.tileSpace(old_space) end
            if Fnutils.contains(allowed_screens, new_screen) then
                if old_screen:getUUID() ~= new_screen:getUUID() then
                    local frame = Space.PaperWM.windows.getWindowFrame(focused_window)
                    local source = old_screen:frame()
                    local destination = new_screen:frame()
                    -- Space membership alone does not necessarily relocate
                    -- a window's pixels onto a different display.
                    if frame.x + frame.w <= destination.x or
                        frame.x >= destination.x + destination.w or
                        frame.y + frame.h <= destination.y or
                        frame.y >= destination.y + destination.h then
                        local x = destination.x + math.max(0,
                            math.min(frame.x - source.x, destination.w - frame.w))
                        local y = destination.y + math.max(0,
                            math.min(frame.y - source.y, destination.h - frame.h))
                        local moved = Space.PaperWM.windows.nativeMoveWindowPosition(
                            focused_window:id(), x, y)
                        if not moved then
                            pcall(focused_window.setTopLeft, focused_window, x, y)
                        end
                    end
                end
                Space.PaperWM.windows.addWindow(focused_window)
                Space.tileSpace(new_space)
                Space.MissionControl:focusSpace(new_space, focused_window)
            end
        end
        Timer.doAfter(0.05, function() finishMove(1) end)
        return
    end

    -- macOS 27 ignores synthetic Mission Control drags. Leave the tiling
    -- state intact when the Dock payload is unavailable instead of removing
    -- the focused window from PaperWM before an impossible fallback.
    if needs_dock_move then
        Space.PaperWM.logger.ef(
            "cannot move window to Space without Dock payload: %s",
            tostring(native_error))
        return
    end

    -- get the old space from the window list or by querying removed window
    local old_space = (function(allowed)
        if allowed then
            return Space.PaperWM.windows.removeWindow(focused_window, true) -- don't switch focus
        end
    end)(Fnutils.contains(allowed_screens, old_screen))

    local ret, err = Space.MissionControl:moveWindowToSpace(focused_window, new_space)
    if not ret or err then
        Space.PaperWM.logger.e(err)
        return
    end

    if old_space then
        Space.tileSpace(old_space)
    end

    if Fnutils.contains(allowed_screens, new_screen) then
        Space.PaperWM.windows.addWindow(focused_window)
        Space.tileSpace(new_space)
        Space.MissionControl:focusSpace(new_space, focused_window)
    end
end

return Space
