#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -project Backpocket.xcodeproj -scheme Backpocket -configuration Release \
    -derivedDataPath .build -quiet build

APP=".build/Build/Products/Release/Backpocket.app"
pkill -x Backpocket 2>/dev/null || true
rm -rf /Applications/Backpocket.app
ditto "$APP" /Applications/Backpocket.app
open /Applications/Backpocket.app
echo "Installed and launched /Applications/Backpocket.app"
