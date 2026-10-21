#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=Transcriber.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library App.swift -o "$APP/Contents/MacOS/Transcriber"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Transcriber</string>
<key>CFBundleExecutable</key><string>Transcriber</string>
<key>CFBundleIdentifier</key><string>local.gary.transcriber</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
codesign --force --sign - "$APP"
