# Native layout backend migration

The target boundary is **Lua decides the layout; native owns its presentation**.
The existing Lua/AX renderer remains available throughout the migration. A
snapshot is never an instruction to resize a window on each animation frame.

## Snapshot contract

Lua sends one complete, versioned snapshot per Space after structural changes:

- Space ID, display ID and display frame, layout generation, focused/anchor ID;
- ordered columns and their window IDs;
- gapless virtual rectangles, measured in points from virtual `(0, 0)`;
- per-window size limits or an explicit fixed-size flag;
- requested edge and inter-window gaps, and animation curve/duration.

Native owns each Space's scroll offset. It converts virtual geometry to
display-local geometry, inserts the gaps, clamps parked windows to that same
display, and emits one presentation transaction. Lua never sends per-frame
positions. Display changes or Space reassignment invalidate the snapshot and
require a new generation; late completions from older generations are ignored.

The native result includes the generation, accepted real window sizes, final
scroll offset, and any window that could not be committed. Lua can then update
its high-level size constraints without reading presentation transforms.

## Processes and ownership

- Hammerspoon/Lua: discovers windows, Space membership and focus; handles
  column order, floating state, user commands, and HUD. Its native module
  submits snapshots and forwards input without layout arithmetic.
- User-session helper: owns virtual scroll, gesture/coasting/snap state, drag
  sampling and reflow, AX window elements, bounded AX size commits, and
  transaction generations. It must be an Accessibility-authorized process.
- Dock payload: only applies compositor moves/transforms on its display link.
  It must not make AX calls or wait for an application to answer one.

The size commit remains an application AX request. Native can conceal its
intermediate backing-size change with an inverse transform, but cannot remove
that compensation while also promising a GPU-smooth resize and a real content
resize. This transform is entirely backend-private; Lua sees only the logical
target and the accepted real size.

## Migration gates

1. **Native resize primitive.** Validate that a single native operation can
   commit AX position/size and install the concealing transform. The current
   in-process prototype is selected by `resize_handoff_backend = "native"`;
   the default stays `"lua"`. This validates semantics, not hang isolation.
2. **User-session AX service.** The initial synchronous service is selected by
   `resize_handoff_backend = "service"`. It has an authenticated local socket,
   bounded AX timeouts, and window ID/PID validation. Grant its binary
   Accessibility access and validate the handoff. Then add asynchronous,
   generation-aware completion before making it the default: the synchronous
   client can still pause Hammerspoon while waiting for a slow app.
3. **Snapshot renderer.** Add a new protocol opcode and a native Space state
   cache. Compare its positions against the current Lua tiler on single- and
   multi-display fixtures before enabling it for keyboard navigation.
4. **Native interactive state.** Move trackpad/HID++ deltas, velocity, coasting,
   snap and keyboard scroll to the backend. Direct manipulation applies the
   latest input without easing; release/retargeting animates. Lua only reports
   semantic focus changes.
5. **Native drag reflow.** Sample the pointer-controlled window's WindowServer
   bounds in the user helper, never write its position while held, and move
   neighbors using the snapshot. Reconcile real sizes on release. Preserve
   display-local clamping, including a grab-able strip for parked windows.
6. **Remove duplicate Lua geometry.** Only after live parity tests, retire
   `Space.tileSpace`'s physical coordinate/gap calculations and Lua swipe/drag
   position loops. Keep the existing AX renderer selectable as fallback.

## Required regression checks

Compare geometry and visual behavior for ordinary navigation, maximized
neighbors, gap toggling, partial off-screen drags, mixed-refresh side-by-side
displays, late AX resize, app-imposed minimum sizes, interrupted animations,
Space reassignment, and Hammerspoon/Dock restarts. A layout generation must
never be committed after a newer one, and no AX call may run on a display-link
thread.
