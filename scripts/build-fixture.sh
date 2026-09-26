#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/English Correct Input Test.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library Tests/Fixtures/InputFixture.swift -o "$APP/Contents/MacOS/InputFixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>English Correct Input Test</string>
<key>CFBundleIdentifier</key><string>local.englishcorrect.inputtest</string>
<key>CFBundleExecutable</key><string>InputFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.englishcorrect.inputtest "$APP"
echo "Built: $APP"
