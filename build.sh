#!/bin/bash
set -e
cd "$(dirname "$0")"
xcodebuild -project Doc2Md.xcodeproj \
    -scheme Doc2Md \
    -configuration Release \
    -derivedDataPath build \
    build

echo ""
echo "=== Build Successful ==="
echo "App: build/Build/Products/Release/Doc2Md.app"
