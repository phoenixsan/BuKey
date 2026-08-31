#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_DIR="$ROOT_DIR/outputs/Layout Pilot.app"
CONTENTS_DIR="$APP_DIR/Contents"
BUILD_DIR="$ROOT_DIR/work/build"

cd "$ROOT_DIR"
mkdir -p "$BUILD_DIR/swift-cache" "$BUILD_DIR/clang-cache"
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/swift-cache" \
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache" \
swiftc -O \
    "$ROOT_DIR/Sources/LayoutPilot/main.swift" \
    -framework AppKit \
    -framework Carbon \
    -framework ServiceManagement \
    -target arm64-apple-macosx13.0 \
    -o "$BUILD_DIR/LayoutPilot"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BUILD_DIR/LayoutPilot" "$CONTENTS_DIR/MacOS/LayoutPilot"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
sips -z 1024 1024 "$ROOT_DIR/Assets/LayoutPilot-1024.png" --out "$CONTENTS_DIR/Resources/LayoutPilot.png" >/dev/null
codesign --force --sign - "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ROOT_DIR/outputs/Layout-Pilot.zip"
echo "$APP_DIR"
echo "$ROOT_DIR/outputs/Layout-Pilot.zip"
