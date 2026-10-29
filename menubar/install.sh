#!/bin/zsh
# Builds the menu bar app, installs it to ~/Applications, starts it at login
# and now. Run again after an update; `install.sh --uninstall` removes it.
set -euo pipefail

NAME="Claude Session Status"
ID="io.github.mr-abdrahimov.claude-session-status"
APP="$HOME/Applications/$NAME.app"
AGENT="$HOME/Library/LaunchAgents/$ID.plist"
HERE="${0:A:h}"

launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$APP" "$AGENT"
  echo "Removed $APP and its login item."
  exit 0
fi

mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"
swiftc -O -o "$APP/Contents/MacOS/SessionStatusBar" "$HERE/SessionStatusBar.swift"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>SessionStatusBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.2</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$ID</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/SessionStatusBar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed $APP; it runs now and at every login."
