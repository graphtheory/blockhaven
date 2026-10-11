#!/bin/sh
# Builds the Mac app that is handed out, as dist/mac/Blockhaven-Mac.dmg:
# Apple silicon and Intel in one binary, built without SDL so it needs
# nothing from Homebrew, signed ad hoc (there is no Developer ID, so a
# downloaded copy still has to be let through once in Privacy & Security).
#
#   Tools/mac/make-app.sh
#
# The version is VERSION plus the commit count, the same number the
# Windows build of this commit gets (see GameVersion.swift).
set -eu
cd "$(dirname "$0")/../.."

BUILD="$(git rev-list --count HEAD)"
VERSION="$(cat VERSION).$BUILD"
SCRATCH=.build/macapp
PRODUCTS="$SCRATCH/apple/Products/Release"
OUT=dist/mac
APP="$OUT/Blockhaven.app"

BLOCKHAVEN_MAC_APP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Blockhaven" "$APP/Contents/MacOS/Blockhaven"
# Loose in Resources rather than in SwiftPM's bundle: see Bundle.shaders.
cp "$PRODUCTS/Blockhaven_Blockhaven.bundle/Contents/Resources/default.metallib" "$APP/Contents/Resources/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Tools/mac/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

# A disk image with the app beside a link to Applications: the usual
# drag-to-install window.
STAGE="$OUT/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Blockhaven" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Blockhaven-Mac.dmg"
rm -rf "$STAGE"
ls -la "$OUT/Blockhaven-Mac.dmg"
echo "version $VERSION"
