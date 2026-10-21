#!/bin/sh
# SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds Transcriber.app (Apple silicon) with swiftc, bundling a whisper-cli built
# by scripts/build-whisper. The version is read from VERSION.txt.
set -e
cd "$(dirname "$0")"
VERSION=$(tr -d '[:space:]' < VERSION.txt)
APP=Transcriber.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
./scripts/build-whisper
cp build/whisper/whisper-cli "$APP/Contents/Resources/whisper-cli"
cp build/whisper/LICENSE "$APP/Contents/Resources/whisper.cpp-LICENSE.txt"
cp brand/app-icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/legal"
cp legal/*.txt "$APP/Contents/Resources/legal/"
cp LICENSE "$APP/Contents/Resources/legal/Transcriber-LICENSE.txt"
swiftc -O -target arm64-apple-macos13.0 -parse-as-library App.swift LocalLLM.swift SessionArchive.swift LicensesView.swift PlaybackMap.swift TrackedText.swift Playback.swift -o "$APP/Contents/MacOS/Transcriber"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Transcriber</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>Transcriber</string>
<key>CFBundleIdentifier</key><string>local.gary.transcriber</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
P
codesign --force --sign - "$APP/Contents/Resources/whisper-cli"
codesign --force --sign - "$APP"
