#!/bin/zsh
# Builds ClaudeUsage.app. Usage:
#   ./build.sh            build into ./build
#   ./build.sh install    build, copy to ~/Applications, start at login, and launch
#   ./build.sh dist       universal (Apple Silicon + Intel) build, zipped with the install
#                         guide into dist/ClaudeUsage.zip for sharing
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClaudeUsage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[[ -f Resources/AppIcon.icns ]] || swift tools/make_icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [[ "${1:-}" == "dist" ]]; then
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos26 Sources/*.swift -o build/ClaudeUsage-$arch
  done
  lipo -create -output "$APP/Contents/MacOS/ClaudeUsage" build/ClaudeUsage-arm64 build/ClaudeUsage-x86_64
  rm -f build/ClaudeUsage-arm64 build/ClaudeUsage-x86_64
else
  swiftc -O -swift-version 5 -target arm64-apple-macos26 \
    Sources/*.swift -o "$APP/Contents/MacOS/ClaudeUsage"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.claude-usage-widget</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "dist" ]]; then
  STAGE=build/dist-stage/ClaudeUsage
  rm -rf build/dist-stage && mkdir -p "$STAGE" dist
  cp -R "$APP" "$STAGE/"
  cp INSTALL.md "$STAGE/How to Install.txt"
  rm -f dist/ClaudeUsage.zip
  ditto -c -k --norsrc --noextattr --keepParent "$STAGE" dist/ClaudeUsage.zip
  rm -rf build/dist-stage
  echo "Packaged dist/ClaudeUsage.zip ($(lipo -archs "$APP/Contents/MacOS/ClaudeUsage"))"
fi

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/ClaudeUsage.app"
  pkill -x ClaudeUsage 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST" && cp -R "$APP" "$DEST"

  AGENT="$HOME/Library/LaunchAgents/local.claude-usage-widget.plist"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.claude-usage-widget</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/ClaudeUsage</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT"
  echo "Installed to $DEST and set to start at login."
fi
