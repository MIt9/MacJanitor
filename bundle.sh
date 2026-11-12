#!/bin/sh
# Build release binary and wrap it in MacJanitor.app (stable bundle id needed for Full Disk Access).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/MacJanitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MacJanitor "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.macjanitor</string>
  <key>CFBundleName</key><string>MacJanitor</string>
  <key>CFBundleExecutable</key><string>MacJanitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
