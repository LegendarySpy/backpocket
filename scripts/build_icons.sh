#!/bin/zsh
# Regenerates the menu-bar template asset from its PNG source. Xcode compiles the app
# icon directly from Icon/icon.icon.
set -euo pipefail
cd "$(dirname "$0")/.."

AC="Backpocket/Assets.xcassets"
SOURCE="Icon/tray.png"

if ! command -v magick >/dev/null; then
    echo "ImageMagick is required to rebuild the menu-bar icon." >&2
    exit 1
fi

for size in 22 44 66; do
    magick "$SOURCE" \
        -colorspace Gray \
        -alpha copy \
        -channel RGB -fill black -colorize 100 +channel \
        -filter Lanczos -resize "${size}x${size}" \
        "$AC/MenuBarIcon.imageset/menubar_${size}.png"
done

echo "Menu-bar icon rebuilt from $SOURCE"
