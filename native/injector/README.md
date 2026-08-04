# PaperWM Dock injector

This optional component injects a small PaperWM payload into Dock so the
native animation helper can move and transform windows through Dock's
WindowServer connection when direct SkyLight writes from Hammerspoon are
denied. Direct SkyLight remains preferred when it works, and PaperWM retains
its Accessibility fallback.

The injector is based on yabai's MIT-licensed arm64e/x86_64 loader. The loader
has only been renamed and pointed at the PaperWM payload. The payload itself is
PaperWM-specific and intentionally implements only:

- a version/capability handshake;
- multi-window position updates; and
- multi-window singular presentation transforms; and
- atomic position/transform commits that never expose the intermediate frame;
  and
- one-shot multi-window animations driven by `CVDisplayLink` inside Dock; and
- display-linked interactive sessions that consume the latest swipe target.

For a normal PaperWM layout animation, Hammerspoon sends one request containing
all window endpoints, duration, and cubic-Bezier control points. The payload
then applies frames at the active displays' refresh cadence, without a Lua timer
or per-frame Hammerspoon-to-Dock IPC. During an interactive gesture, IPC only
replaces a small latest-target buffer; Dock applies at most one update per
display refresh instead of moving every window synchronously in the request.

Transient position updates do not reassociate windows with spaces.

## Prerequisites

Injection requires a macOS configuration that permits `task_for_pid` access to
Dock. As with yabai's scripting addition, Filesystem Protections and Debugging
Restrictions must be disabled from Recovery. Apple Silicon must also permit
running an ad-hoc signed arm64e loader and payload. These are system security
changes; this installer does not make them for you.

## Build and install

Run as the logged-in desktop user:

```sh
cd PaperWM.spoon/native/injector
make check
./install.sh
```

Do not run `install.sh` itself through `sudo`. It requests sudo only while
installing the system-owned helper and scripting-addition bundle. The installer
adds one digest-pinned sudoers command:

```text
/Library/PrivilegedHelperTools/paperwm-injector --inject
```

It also installs a per-user LaunchAgent at
`~/Library/LaunchAgents/org.paperwm.hammerspoon.injector.plist`. The agent
checks the payload after login and whenever Dock restarts, then invokes the
single permitted injection command if necessary.

Check the current payload:

```sh
/Library/PrivilegedHelperTools/paperwm-injector --status
```

Exercise move, transform, and restoration against a disposable borderless
window:

```sh
make probe
```

Logs are written to `/tmp/paperwm-injector-UID.out.log` and
`/tmp/paperwm-injector-UID.err.log`. Completed display-link animations and
interactive sessions append cadence measurements to
`/tmp/paperwm-payload-UID.log`.

## Uninstall

```sh
cd PaperWM.spoon/native/injector
./install.sh --uninstall
```

Uninstalling removes the LaunchAgent, sudoers rule, installed helper, and
PaperWM scripting addition. A payload already loaded into Dock remains mapped
until Dock restarts or the user logs out.

## Installed files

- `/Library/ScriptingAdditions/PaperWM.osax`
- `/Library/PrivilegedHelperTools/paperwm-injector`
- `/etc/sudoers.d/paperwm-injector-UID`
- `~/Library/LaunchAgents/org.paperwm.hammerspoon.injector.plist`

See `LICENSE.yabai` for the loader's upstream license.
