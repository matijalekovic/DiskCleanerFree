#!/bin/zsh
# Builds the app and packages it as a drag-to-install disk image: build/DiskCleanerFree-<version>.dmg
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="Disk Cleaner Free"
VERSION="${VERSION:-1.0}"
BUILD="$ROOT/build"
STAGING="$BUILD/dmg"
DMG="$BUILD/DiskCleanerFree-$VERSION.dmg"

VERSION="$VERSION" "$ROOT/scripts/build_app.sh"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$BUILD/$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/How to open.txt" <<'TXT'
Disk Cleaner Free — installing

1. Drag "Disk Cleaner Free" onto the Applications folder.
2. Open it from Applications.

The app isn't signed with an Apple Developer ID, so the first time macOS says it
can't verify the developer. To open it anyway:

  • Open System Settings › Privacy & Security, scroll down, and click "Open Anyway"
    next to the message about Disk Cleaner Free. Confirm with your password.

  or, in Terminal:

    xattr -dr com.apple.quarantine "/Applications/Disk Cleaner Free.app"

You only need to do this once. Requires macOS 26 or later (Apple Silicon or Intel).
TXT

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGING"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
