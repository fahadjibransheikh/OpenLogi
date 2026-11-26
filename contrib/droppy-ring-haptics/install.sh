#!/bin/sh
# Builds ring-buzz and installs it as a login item (a per-user LaunchAgent).
#
#   ./install.sh                      # uses /opt/homebrew/bin/openlogi, production agent
#   OPENLOGI=/path/to/openlogi OPENLOGI_PROFILE=dev ./install.sh
#   ./install.sh --uninstall
set -eu

label=org.openlogi.contrib.ring-buzz
dir="$HOME/Library/Application Support/ring-buzz"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

launchctl bootout "$domain/$label" 2>/dev/null || true
if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$plist"
    rm -rf "$dir"
    echo "ring-buzz removed"
    exit 0
fi

openlogi="${OPENLOGI:-/opt/homebrew/bin/openlogi}"
[ -x "$openlogi" ] || { echo "no openlogi CLI at $openlogi (set OPENLOGI=)" >&2; exit 1; }

mkdir -p "$dir" "$HOME/Library/LaunchAgents"
src="$(cd "$(dirname "$0")" && pwd)/RingBuzz.swift"
swiftc -O "$src" -o "$dir/ring-buzz"
"$dir/ring-buzz" --self-check
# A stable identifier keeps the Accessibility grant tied to this tool's name.
codesign --force --sign - --identifier "$label" "$dir/ring-buzz"

profile_env=""
if [ -n "${OPENLOGI_PROFILE:-}" ]; then
    profile_env="<key>EnvironmentVariables</key><dict><key>OPENLOGI_PROFILE</key><string>$OPENLOGI_PROFILE</string></dict>"
fi

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$dir/ring-buzz</string>
        <string>$openlogi</string>
        <string>haptic</string>
        <string>play</string>
        <string>tick</string>
    </array>
    $profile_env
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardErrorPath</key><string>$dir/ring-buzz.log</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
plutil -lint "$plist" >/dev/null
launchctl bootstrap "$domain" "$plist"
echo "ring-buzz installed; grant it Accessibility if macOS asks (log: $dir/ring-buzz.log)"
