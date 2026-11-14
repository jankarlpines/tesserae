#!/bin/zsh
# Builds Tesserae.app next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Tesserae.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Tesserae $APP/Contents/MacOS/Tesserae
cp icon/Tesserae.icns $APP/Contents/Resources/Tesserae.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Tesserae</string>
  <key>CFBundleDisplayName</key><string>Tesserae</string>
  <key>CFBundleIdentifier</key><string>local.tesserae</string>
  <key>CFBundleIconFile</key><string>Tesserae</string>
  <key>CFBundleExecutable</key><string>Tesserae</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force -s - $APP >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP"
