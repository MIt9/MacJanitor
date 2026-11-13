#!/bin/sh
# Build release binary and wrap it in MacJanitor.app (stable bundle id needed for Full Disk Access).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/MacJanitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MacJanitorGUI "$APP/Contents/MacOS/MacJanitor"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.macjanitor</string>
  <key>CFBundleName</key><string>MacJanitor</string>
  <key>CFBundleExecutable</key><string>MacJanitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>uk</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
SIGNING_IDENTITY=${MACJANITOR_SIGNING_IDENTITY:-91C99B81BA46DDC1AD68DDAB8CB6258B4C51844A}
if [ "$SIGNING_IDENTITY" = "-" ]; then
  echo "Ad hoc signing is not supported; select a code-signing identity." >&2
  exit 1
fi
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
