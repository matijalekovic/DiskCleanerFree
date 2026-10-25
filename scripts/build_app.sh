#!/bin/zsh
# Builds "Disk Cleaner Free.app" into ./build using only the Command Line Tools.
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="Disk Cleaner Free"
EXEC="DiskCleanerFree"
BUNDLE_ID="com.diskcleanerfree.app"
VERSION="${VERSION:-1.0}"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"

cd "$ROOT"
# Universal binary: build each architecture, then merge (multi-arch builds need full Xcode).
swift build -c release --arch arm64
swift build -c release --arch x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/$EXEC" \
  ".build/arm64-apple-macosx/release/$EXEC" \
  ".build/x86_64-apple-macosx/release/$EXEC"

# App icon
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$BUILD/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$BUILD/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Matija Lekovic</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.volume</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
