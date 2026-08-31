#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_DIR="$ROOT_DIR/outputs/BuKey.app"
CONTENTS_DIR="$APP_DIR/Contents"
BUILD_DIR="$ROOT_DIR/work/build"

cd "$ROOT_DIR"
mkdir -p "$BUILD_DIR/swift-cache" "$BUILD_DIR/clang-cache"
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/swift-cache" \
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache" \
swiftc -O \
    "$ROOT_DIR/Sources/BuKey/main.swift" \
    -framework AppKit \
    -framework Carbon \
    -framework ServiceManagement \
    -target arm64-apple-macosx13.0 \
    -o "$BUILD_DIR/BuKey"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BUILD_DIR/BuKey" "$CONTENTS_DIR/MacOS/BuKey"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
sips -z 1024 1024 "$ROOT_DIR/Assets/BuKey-1024.png" --out "$CONTENTS_DIR/Resources/BuKey.png" >/dev/null
codesign --force --sign - "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ROOT_DIR/outputs/BuKey.zip"
echo "$APP_DIR"
echo "$ROOT_DIR/outputs/BuKey.zip"
