local WindowFilter <const> = hs.window.filter

local Config = {}
Config.__index = Config

---default configuration
Config.default_hotkeys = {
    stop_events          = { { "alt", "cmd", "shift" }, "q" },
    refresh_windows      = { { "alt", "cmd", "shift" }, "r" },
    dump_state           = { { "alt", "cmd", "shift" }, "d" },
    toggle_floating      = { { "alt", "cmd", "shift" }, "escape" },
    focus_left           = { { "alt", "cmd" }, "left" },
    focus_right          = { { "alt", "cmd" }, "right" },
    focus_up             = { { "alt", "cmd" }, "up" },
    focus_down           = { { "alt", "cmd" }, "down" },
    swap_left            = { { "alt", "cmd", "shift" }, "left" },
    swap_right           = { { "alt", "cmd", "shift" }, "right" },
    swap_up              = { { "alt", "cmd", "shift" }, "up" },
    swap_down            = { { "alt", "cmd", "shift" }, "down" },
    center_window        = { { "alt", "cmd" }, "c" },
    full_width           = { { "alt", "cmd" }, "f" },
    cycle_width          = { { "alt", "cmd" }, "r" },
    cycle_height         = { { "alt", "cmd", "shift" }, "r" },
    reverse_cycle_width  = { { "ctrl", "alt", "cmd" }, "r" },
    reverse_cycle_height = { { "ctrl", "alt", "cmd", "shift" }, "r" },
    slurp_in             = { { "alt", "cmd" }, "i" },
    barf_out             = { { "alt", "cmd" }, "o" },
    switch_space_l       = { { "alt", "cmd" }, "," },
    switch_space_r       = { { "alt", "cmd" }, "." },
    switch_space_1       = { { "alt", "cmd" }, "1" },
    switch_space_2       = { { "alt", "cmd" }, "2" },
    switch_space_3       = { { "alt", "cmd" }, "3" },
    switch_space_4       = { { "alt", "cmd" }, "4" },
    switch_space_5       = { { "alt", "cmd" }, "5" },
    switch_space_6       = { { "alt", "cmd" }, "6" },
    switch_space_7       = { { "alt", "cmd" }, "7" },
    switch_space_8       = { { "alt", "cmd" }, "8" },
    switch_space_9       = { { "alt", "cmd" }, "9" },
    move_window_1        = { { "alt", "cmd", "shift" }, "1" },
    move_window_2        = { { "alt", "cmd", "shift" }, "2" },
    move_window_3        = { { "alt", "cmd", "shift" }, "3" },
    move_window_4        = { { "alt", "cmd", "shift" }, "4" },
    move_window_5        = { { "alt", "cmd", "shift" }, "5" },
    move_window_6        = { { "alt", "cmd", "shift" }, "6" },
    move_window_7        = { { "alt", "cmd", "shift" }, "7" },
    move_window_8        = { { "alt", "cmd", "shift" }, "8" },
    move_window_9        = { { "alt", "cmd", "shift" }, "9" },
}

---filter for windows to manage
Config.window_filter = WindowFilter.new():setOverrideFilter({
    visible = true,
    fullscreen = false,
    hasTitlebar = true,
    allowRoles = "AXStandardWindow",
})

---window gaps: can be set as a single number or a table with top, bottom, left, right values
Config.window_gap = 8 ---@type number|{ top: number, bottom: number, left: number, right: number }

---ratios to use when cycling widths and heights, golden ratio by default
Config.window_ratios = { 0.23607, 0.38195, 0.61804 } ---@type number[]

---window animation backend: "accessibility" or experimental "native"
---the native backend prefers direct SkyLight, then an installed Dock payload,
---and falls back to Accessibility when neither native route can write
Config.animation_backend = "native" ---@type "accessibility"|"native"

---legacy native and Accessibility position-animation timer frequency;
---Dock-backed animations use the display's refresh cadence instead
Config.animation_fps = 120 ---@type number

---CSS-style cubic Bezier timing curve: { x1, y1, x2, y2 }
---x values must be between 0 and 1; y values may extend beyond that range
Config.animation_curve = { 0.2, 0.0, 0.0, 1.0 } ---@type number[]

---maximum time in seconds for an Accessibility window request
---this protects Hammerspoon when an owning application is unresponsive
Config.ax_timeout = 0.2 ---@type number

---size of the on-screen margin to place off-screen windows
Config.screen_margin = 1 ---@type number

---number of fingers to detect a horizontal swipe, set to 0 to disable
Config.swipe_fingers = 0 ---@type number

---increase this number to make windows move futher when swiping
Config.swipe_gain = 1 ---@type number

---normalized touch travel before locking a trackpad swipe to an axis
Config.swipe_direction_threshold = 0.01 ---@type number

---accept horizontal RawXY from a passively observed Logitech gesture button
Config.mouse_swipe = false ---@type boolean

---multiplier for HID++ RawXY deltas
Config.mouse_swipe_gain = 1 ---@type number

---reverse horizontal HID++ gesture direction
Config.mouse_swipe_invert = false ---@type boolean

---accumulated RawXY travel before locking the gesture to an axis
Config.mouse_swipe_direction_threshold = 1 ---@type number

---device-local HID++ feature index observed for REPROG_CONTROLS_V4
Config.mouse_swipe_hidpp_feature_index = 0x09 ---@type number

---HID++ control ID for the MX Master 3 gesture button
Config.mouse_swipe_hidpp_cid = 0x00c3 ---@type number

---seconds between RawXY accumulator polls
Config.mouse_swipe_poll_interval = 1 / 120 ---@type number

---distance in pixels between trackpad haptic ticks while swiping, set to 0 to disable
Config.swipe_haptic_interval = 120 ---@type number

---idle time in seconds before normalizing layout after a swipe
Config.swipe_settle_delay = 0.25 ---@type number

---continue native swipe movement with release velocity
Config.swipe_inertia = true ---@type boolean

---exponential velocity decay per second; lower values coast farther
Config.swipe_inertia_friction = 3.5 ---@type number

---minimum release velocity in pixels per second needed to coast
Config.swipe_inertia_min_velocity = 40 ---@type number

---maximum release velocity in pixels per second
Config.swipe_inertia_max_velocity = 6000 ---@type number

---write detailed gesture timing to /tmp/paperwm_swipe_trace.log
Config.swipe_debug_trace = false ---@type boolean

---write compact animation and gesture summaries to /tmp/paperwm_diagnostics.log
Config.diagnostics_trace = true ---@type boolean

---center mouse cursor on screen after switching spaces
Config.center_mouse = true ---@type boolean

return Config
