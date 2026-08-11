# PaperWM.spoon

Tiled scrollable window manager for MacOS. Inspired by
[PaperWM](https://github.com/paperwm/PaperWM).

Spoon plugin for [HammerSpoon](https://www.hammerspoon.org) MacOS automation
app.

# Demo

https://user-images.githubusercontent.com/900731/147793584-f937811a-20aa-4282-baf5-035e5ddc12ea.mp4

## Installation

1. Clone to Hammerspoon Spoons directory: `git clone
https://github.com/mogenson/PaperWM.spoon ~/.hammerspoon/Spoons/PaperWM.spoon`.

2. Open `System Preferences` -> `Desktop and Dock`. Scroll to the bottom to
"Mission Control", then uncheck "Automatically rearrange Spaces based on most
recent use" and check "Displays have separate Spaces".

<img width="780" src="https://github.com/user-attachments/assets/b0842c44-2a3b-43fc-85eb-66729cd7f8db">

### Install with [SpoonInstall](https://www.hammerspoon.org/Spoons/SpoonInstall.html)

```lua
hs.loadSpoon("SpoonInstall")

spoon.SpoonInstall.repos.PaperWM = {
    url = "https://github.com/mogenson/PaperWM.spoon",
    desc = "PaperWM.spoon repository",
    branch = "release",
}

spoon.SpoonInstall:andUse("PaperWM", {
    repo = "PaperWM",
    config = { screen_margin = 16, window_gap = 2 },
    start = true,
    hotkeys = {
        < see below >
    }
})
```

## Usage

Add the following to your `~/.hammerspoon/init.lua`:

```lua
PaperWM = hs.loadSpoon("PaperWM")
PaperWM:bindHotkeys({
    -- switch to a new focused window in tiled grid
    focus_left  = {{"alt", "cmd"}, "left"},
    focus_right = {{"alt", "cmd"}, "right"},
    focus_up    = {{"alt", "cmd"}, "up"},
    focus_down  = {{"alt", "cmd"}, "down"},

    -- switch windows by cycling forward/backward
    -- (forward = down or right, backward = up or left)
    focus_prev = {{"alt", "cmd"}, "k"},
    focus_next = {{"alt", "cmd"}, "j"},

    -- move windows around in tiled grid
    swap_left  = {{"alt", "cmd", "shift"}, "left"},
    swap_right = {{"alt", "cmd", "shift"}, "right"},
    swap_up    = {{"alt", "cmd", "shift"}, "up"},
    swap_down  = {{"alt", "cmd", "shift"}, "down"},

    -- alternative: swap entire columns, rather than
    -- individual windows (to be used instead of
    -- swap_left / swap_right bindings)
    -- swap_column_left = {{"alt", "cmd", "shift"}, "left"},
    -- swap_column_right = {{"alt", "cmd", "shift"}, "right"},

    -- position and resize focused window
    center_window        = {{"alt", "cmd"}, "c"},
    full_width           = {{"alt", "cmd"}, "f"},
    cycle_width          = {{"alt", "cmd"}, "r"},
    reverse_cycle_width  = {{"ctrl", "alt", "cmd"}, "r"},
    cycle_height         = {{"alt", "cmd", "shift"}, "r"},
    reverse_cycle_height = {{"ctrl", "alt", "cmd", "shift"}, "r"},

    -- increase/decrease width
    increase_width = {{"alt", "cmd"}, "l"},
    decrease_width = {{"alt", "cmd"}, "h"},

    -- move focused window into / out of a column
    slurp_in = {{"alt", "cmd"}, "i"},
    barf_out = {{"alt", "cmd"}, "o"},

    -- move the focused window into / out of the tiling layer
    toggle_floating = {{"alt", "cmd", "shift"}, "escape"},

    -- focus the first / second / etc window in the current space
    focus_window_1 = {{"cmd", "shift"}, "1"},
    focus_window_2 = {{"cmd", "shift"}, "2"},
    focus_window_3 = {{"cmd", "shift"}, "3"},
    focus_window_4 = {{"cmd", "shift"}, "4"},
    focus_window_5 = {{"cmd", "shift"}, "5"},
    focus_window_6 = {{"cmd", "shift"}, "6"},
    focus_window_7 = {{"cmd", "shift"}, "7"},
    focus_window_8 = {{"cmd", "shift"}, "8"},
    focus_window_9 = {{"cmd", "shift"}, "9"},

    -- switch to a new Mission Control space
    switch_space_l = {{"alt", "cmd"}, ","},
    switch_space_r = {{"alt", "cmd"}, "."},
    switch_space_1 = {{"alt", "cmd"}, "1"},
    switch_space_2 = {{"alt", "cmd"}, "2"},
    switch_space_3 = {{"alt", "cmd"}, "3"},
    switch_space_4 = {{"alt", "cmd"}, "4"},
    switch_space_5 = {{"alt", "cmd"}, "5"},
    switch_space_6 = {{"alt", "cmd"}, "6"},
    switch_space_7 = {{"alt", "cmd"}, "7"},
    switch_space_8 = {{"alt", "cmd"}, "8"},
    switch_space_9 = {{"alt", "cmd"}, "9"},

    -- move focused window to a new space and tile
    move_window_1 = {{"alt", "cmd", "shift"}, "1"},
    move_window_2 = {{"alt", "cmd", "shift"}, "2"},
    move_window_3 = {{"alt", "cmd", "shift"}, "3"},
    move_window_4 = {{"alt", "cmd", "shift"}, "4"},
    move_window_5 = {{"alt", "cmd", "shift"}, "5"},
    move_window_6 = {{"alt", "cmd", "shift"}, "6"},
    move_window_7 = {{"alt", "cmd", "shift"}, "7"},
    move_window_8 = {{"alt", "cmd", "shift"}, "8"},
    move_window_9 = {{"alt", "cmd", "shift"}, "9"}
})
PaperWM:start()
```

Feel free to customize hotkeys or use
`PaperWM:bindHotkeys(PaperWM.default_hotkeys)` for defaults. PaperWM actions are
also available for manual keybinding. The `PaperWM.actions.actions()` function
will return a table of action names and functions to call.

For example, the following config uses a hyper key and a modal layer to navigate
windows with the h/j/k/l keys, like vim:

```lua
PaperWM = hs.loadSpoon("PaperWM")
PaperWM:bindHotkeys(PaperWM.default_hotkeys)

-- use ⌘ Enter as hyper key to enter modal layer, press Escape to exit
local modal = hs.hotkey.modal.new({ "cmd" }, "return")

local actions = PaperWM.actions.actions()
modal:bind({}, "h", nil, actions.focus_left)
modal:bind({}, "j", nil, actions.focus_down)
modal:bind({}, "k", nil, actions.focus_up)
modal:bind({}, "l", nil, actions.focus_right)
```

`PaperWM:start()` will begin automatically tiling new and existing windows.
`PaperWM:stop()` will release control over windows.

Set `PaperWM.window_gap` to the number of pixels between windows and screen
edges. This can be a single number for all sides, or a table specifying `top`,
`bottom`, `left`, and `right` gaps individually.

For example:
```lua
-- 10px gap on all sides
PaperWM.window_gap = 10
-- or specific gaps per side
PaperWM.window_gap  =  { top = 10, bottom = 8, left = 12, right = 12 }
```

### Experimental native animations

PaperWM can animate window position and size changes, including interactive
swipe scrolling, using WindowServer presentation transforms instead of sending
an Accessibility update for every frame. This uses private, undocumented macOS
APIs and may stop working after an OS update.

Build the helper for the installed Hammerspoon:

```sh
make -C ~/.hammerspoon/Spoons/PaperWM.spoon/native
```

On macOS versions that reject foreign-window writes from Hammerspoon, the
optional Dock injector provides the same native interface through Dock's
WindowServer connection. It requires the same partial SIP configuration as
yabai's scripting addition. Build and install it as the logged-in user:

```sh
cd ~/.hammerspoon/Spoons/PaperWM.spoon/native/injector
make check
./install.sh
```

The installer creates a narrowly scoped, digest-pinned sudoers command and a
per-user LaunchAgent that reinjects after Dock restarts. See
[`native/injector/README.md`](native/injector/README.md) for the installed
files, security prerequisites, status command, and uninstall instructions.

```lua
PaperWM.animation_backend = "native" -- default for this experimental build

-- CSS-style cubic-bezier(x1, y1, x2, y2)
PaperWM.animation_curve = { 0.2, 0.0, 0.0, 1.0 }

-- Bound synchronous AX calls when an application is hung (seconds).
PaperWM.ax_timeout = 0.2
```

The curve can be changed on the active Spoon at runtime, so experimenting in
the Hammerspoon Console does not require a reload. The x control points must be
between `0` and `1`; y values outside that range are allowed for overshoot:

```lua
PaperWM.animation_curve = { 0.25, 0.1, 0.25, 1.0 } -- CSS "ease"
PaperWM.animation_curve = { x1 = 0.34, y1 = 1.56, x2 = 0.64, y2 = 1.0 }
PaperWM.windows.sampleAnimationCurve(0.5) -- inspect the curve at 50% time
```

Use `"accessibility"` to select the standard path. The native path reads real
window bounds from public WindowServer metadata and commits position changes
directly. Resizes still require Accessibility; they use `ax_timeout`, and a
window that does not respond keeps its compositor presentation while PaperWM
retries with backoff. `hs.window.timeout` is process-wide, so `ax_timeout`
also bounds other Hammerspoon window Accessibility calls while PaperWM runs.
The native helper prefers direct SkyLight writes, then the installed Dock
payload. If neither native route is available, PaperWM falls back to
Accessibility animation. With the Dock payload, each layout transition is sent
once and animated inside Dock using `CVDisplayLink`; there is no per-frame Lua
timer or per-frame Hammerspoon-to-Dock IPC. Direct SkyLight and older payloads
retain the configurable legacy timer path (`PaperWM.animation_fps = 120`).

Configure the `PaperWM.window_filter` to set which apps and screens are managed.
For example:

```lua
-- ignore a specific app
PaperWM.window_filter:rejectApp("iStat Menus Status")
-- list of screens to tile (use % to escape string match characters, like -)
PaperWM.window_filter:setScreens({ "Built%-in Retina Display" })
-- restart for new window filter to take effect
PaperWM:start()
```

Set `PaperWM.center_mouse` to control whether the mouse cursor is centered on
the screen after switching spaces. Default is `true`. Example:

```lua
-- disable mouse centering when switching spaces
PaperWM.center_mouse = false
```

Set `PaperWM.window_ratios` to the ratios to cycle window widths and heights
through. For example:

```lua
PaperWM.window_ratios = { 1/3, 1/2, 2/3 }
```

### Smooth Scrolling

https://github.com/user-attachments/assets/6f1c4659-0ca8-4ba1-a181-8c1c6987e8ef

PaperWM.spoon can scroll windows left or right by swiping fingers horizontally
across the trackpad. Set the number of fingers (eg. 2, 3, or 4) and, optionally,
a gain to adjust the sensitivity:

```lua
-- number of fingers to detect a horizontal swipe, set to 0 to disable (the default)
PaperWM.swipe_fingers = 0

-- increase this number to make windows move farther when swiping
PaperWM.swipe_gain = 1.0

-- pixels of window travel between haptic ticks; set to 0 to disable
PaperWM.swipe_haptic_interval = 120

-- idle time before the post-swipe layout pass; rapid swipes cancel this timer
PaperWM.swipe_settle_delay = 0.25

-- continue moving with release velocity; lower friction coasts farther
PaperWM.swipe_inertia = true
PaperWM.swipe_inertia_friction = 3.5
PaperWM.swipe_inertia_min_velocity = 40
PaperWM.swipe_inertia_max_velocity = 6000

-- Optional: use passive HID++ RawXY from an MX Master gesture button.
PaperWM.mouse_swipe = true
PaperWM.mouse_swipe_gain = 1
PaperWM.mouse_swipe_invert = false
PaperWM.mouse_swipe_hidpp_feature_index = 0x09
PaperWM.mouse_swipe_hidpp_cid = 0x00c3
```

For an MX Master 3 or 3S connected through a receiver or Bluetooth, configure
the Options+ gesture button as **Custom**, set left and right to **Do Nothing**,
and keep up assigned to Mission Control. `mouse_swipe` observes the gesture
button and RawXY reports without changing the device's diversion settings.
Horizontal thumb-wheel and trackpad scroll events are not intercepted. The
feature index and CID are device-specific values obtained from passive HID++
observation.

Haptic feedback uses the system's current trackpad feedback performer. Ticks are
based on accumulated horizontal travel, so longer swipes produce more feedback
and faster swipes reach each tick sooner. macOS may suppress feedback when no
haptic-capable trackpad is active or the trackpad is not being touched.

Native swipes coast with the release velocity and stop at the first or last
window without changing spacing within the strip. Layout snapping is deferred
until the fingers, inertia, and settle delay have all finished. A swipe that
starts during a native resize animation is ignored until that animation ends.
Inspect `hs.inspect(PaperWM.events.swipeStatus())` in the Hammerspoon console
to see the measured release velocity and any reason inertia was skipped.

Inspired by [ScrollDesktop.spoon](https://github.com/jocap/ScrollDesktop.spoon)

### Mouse Dragging

https://github.com/user-attachments/assets/61a0afda-93e6-41b3-963c-7681a4bbe7c7

Click and drag a window with the mouse while holding the `PaperWM.drag_window`
hotkey to slide and reposition all the windows on a space.

Click on a window with the `PaperWM.lift_window` hotkey held to lift it up, drag
to move the window, and release the mouse to drop it in a new tiled location.
This is useful for moving a window to a new screen.

```lua
-- set to a table of modifier keys to enable window dragging, default is nil
PaperWM.drag_window = { "alt", "cmd" }`

-- set to a table of modifier keys to enable window lifting, default is nil
PaperWM.lift_window = { "alt", "cmd", "shift" }
```

## Limitations

MacOS does not allow a window to be moved fully off-screen. Windows that would
be tiled off-screen are placed in a margin on the left and right edge of the
screen. They are still visible and clickable.

It's difficult to detect when a window is dragged from one space or screen to
another. Use the `move_window_N` commands to move windows between spaces and
screens.

Arrange screens vertically to prevent windows from bleeding into other screens.
Use [WarpMouse.spoon](https://github.com/mogenson/WarpMouse.spoon) to simulate
side-by-side screens.

<img width="780" src="https://user-images.githubusercontent.com/900731/148595785-546f9086-9add-4731-8477-233b202378f4.png">

## Add-ons

The following spoons compliment PaperWM.spoon nicely.

- [ActiveSpace.spoon](https://github.com/mogenson/ActiveSpace.spoon) Show active
and layout of Mission Control spaces in the menu bar.
- [WarpMouse.spoon](https://github.com/mogenson/WarpMouse.spoon) Move mouse
cursor between screen edges to simulate side-by-side screens.
- [Swipe.spoon](https://github.com/mogenson/Swipe.spoon) Perform actions when
trackpad swipe gestures are recognized. Here's an example config to change
PaperWM.spoon focused window:
```lua
-- focus adjacent window with 3 finger swipe
local actions = PaperWM.actions.actions()
local current_id, threshold
Swipe = hs.loadSpoon("Swipe")
Swipe:start(3, function(direction, distance, id)
    if id == current_id then
        if distance > threshold then
            threshold = math.huge -- trigger once per swipe

            -- use "natural" scrolling
            if direction == "left" then
                actions.focus_right()
            elseif direction == "right" then
                actions.focus_left()
            elseif direction == "up" then
                actions.focus_down()
            elseif direction == "down" then
                actions.focus_up()
            end
        end
    else
        current_id = id
        threshold = 0.2 -- swipe distance > 20% of trackpad size
    end
end)
```
- [FocusMode.spoon](https://github.com/selimacerbas/FocusMode.spoon) Helps you
stay in flow by dimming everything except what you’re working on.

## Contributing

Contributions are welcome! Here are a few preferences:
- Global variables are `PascalCase` (eg. `PaperWM`)
- Local variables are `snake_case` (eg. `local focused_window`)
- Function names are `camelCase` (eg. `function windowEventHandler()`)
- Use `<const>` where possible
- Create a local copy when deeply nested members are used often (eg. `local
Watcher <const> = hs.uielement.watcher`)

Code format checking and linting is provided by
[lua-language-server](https://github.com/LuaLS/lua-language-server) for commits
and pull requests. Run `lua-language-server --check .` locally before commiting.

[Busted](https://lunarmodules.github.io/busted/) is used for unit testing. Run
`busted` from the repo root to run tests locally.
