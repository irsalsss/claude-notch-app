#!/bin/zsh
# Build ClaudeNotch.app into ~/Applications and (re)load its launch agent.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/ClaudeNotch.app"
LABEL="com.irsalsss.claude-notch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library ClaudeNotch.swift -o "$APP/Contents/MacOS/ClaudeNotch"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>ClaudeNotch</string>
  <key>CFBundleExecutable</key><string>ClaudeNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ClaudeNotch selects the terminal tab of the session you click.</string>
</dict></plist>
PL
codesign --force --sign - "$APP" >/dev/null

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ClaudeNotch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "ClaudeNotch running (launchd: $LABEL)"
