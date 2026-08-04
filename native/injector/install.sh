#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
BUILD_DIR="$SCRIPT_DIR/build"
LABEL="org.paperwm.hammerspoon.injector"
HELPER="/Library/PrivilegedHelperTools/paperwm-injector"
OSAX="/Library/ScriptingAdditions/PaperWM.osax"
USER_UID=$(id -u)
USER_NAME=$(id -un)
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SUDOERS="/etc/sudoers.d/paperwm-injector-$USER_UID"

if [[ $EUID -eq 0 ]]; then
    print -u2 "Run this installer as the logged-in user, not through sudo."
    print -u2 "It will request sudo only for the installed payload and sudoers rule."
    exit 1
fi

unload_agent() {
    launchctl bootout "gui/$USER_UID/$LABEL" >/dev/null 2>&1 || true
}

uninstall() {
    unload_agent
    rm -f "$LAUNCH_AGENT"
    sudo rm -f "$SUDOERS" "$HELPER"
    sudo rm -rf "$OSAX"
    print "PaperWM injector removed."
    print "The already-loaded payload remains in Dock until Dock restarts or you log out."
}

if [[ ${1:-} == "--uninstall" ]]; then
    uninstall
    exit 0
fi

if [[ ${1:-} != "--no-build" ]]; then
    make -C "$SCRIPT_DIR" check
elif [[ ! -x "$BUILD_DIR/paperwm-injector" ]]; then
    print -u2 "Build artifacts are missing; run make first."
    exit 1
fi

if [[ ! -x "$BUILD_DIR/PaperWM.osax/Contents/MacOS/loader" ||
      ! -x "$BUILD_DIR/PaperWM.osax/Contents/Resources/payload.bundle/Contents/MacOS/payload" ]]; then
    print -u2 "The PaperWM scripting-addition bundle is incomplete."
    exit 1
fi

updated_install=false
if [[ -e "$OSAX/Contents/MacOS/loader" ]]; then
    updated_install=true
fi

temporary=$(mktemp -d "${TMPDIR:-/tmp}/paperwm-injector.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

print "Installing PaperWM injector (sudo is limited to system-owned files)..."
sudo -v
sudo install -d -m 0755 "/Library/PrivilegedHelperTools"
sudo rm -rf "$OSAX"
sudo /usr/bin/ditto "$BUILD_DIR/PaperWM.osax" "$OSAX"
sudo chown -R root:wheel "$OSAX"
sudo install -m 0755 "$BUILD_DIR/paperwm-injector" "$HELPER"

helper_hash=$(shasum -a 256 "$HELPER" | awk '{print $1}')
print -r -- "$USER_NAME ALL=(root) NOPASSWD: sha256:$helper_hash $HELPER --inject" \
    > "$temporary/sudoers"
chmod 0440 "$temporary/sudoers"
sudo /usr/sbin/visudo -cf "$temporary/sudoers"
sudo install -o root -g wheel -m 0440 "$temporary/sudoers" "$SUDOERS"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$temporary/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HELPER</string>
        <string>--monitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/paperwm-injector-$USER_UID.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/paperwm-injector-$USER_UID.err.log</string>
</dict>
</plist>
PLIST
plutil -lint "$temporary/$LABEL.plist"
install -m 0644 "$temporary/$LABEL.plist" "$LAUNCH_AGENT"

unload_agent
if $updated_install; then
    print "Restarting Dock once to activate the updated payload..."
    /usr/bin/killall Dock >/dev/null 2>&1 || true
fi
launchctl bootstrap "gui/$USER_UID" "$LAUNCH_AGENT"
launchctl kickstart -k "gui/$USER_UID/$LABEL"

for attempt in {1..40}; do
    if "$HELPER" --status; then
        print "PaperWM injector installed and automatic Dock reinjection is active."
        exit 0
    fi
    sleep 0.1
done

print -u2 "The service was installed, but the payload handshake did not become ready."
print -u2 "Inspect /tmp/paperwm-injector-$USER_UID.err.log for the injection error."
exit 1
