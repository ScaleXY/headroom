#!/bin/zsh
# Renders assets/icon.svg as the iPhone, iPad and Watch app icon: a full-bleed, fully opaque
# 1024 px square (the system applies its own corner mask; App Store Connect rejects any alpha).
# Needs rsvg-convert and ImageMagick (brew install librsvg imagemagick).
set -euo pipefail
cd "${0:A:h}/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Square the background and drop the hairline outline, which only suit the macOS rounded tile.
sed -e 's|<rect width="64" height="64" rx="15" fill="url(#bg)"/>|<rect width="64" height="64" fill="url(#bg)"/>|' \
    -e '/stroke-opacity=".12"/d' assets/icon.svg > "$work/square.svg"
grep -q '<rect width="64" height="64" fill="url(#bg)"/>' "$work/square.svg" || { echo "error: assets/icon.svg's background changed; update this script" >&2; exit 1; }
rsvg-convert -w 1024 -h 1024 "$work/square.svg" -o "$work/art.png"
for target in Mobile/App Mobile/Watch; do
  magick "$work/art.png" -background '#0E0F13' -alpha remove -alpha off -define png:color-type=2 \
    "$target/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
done
echo "wrote Mobile/App and Mobile/Watch AppIcon (1024 px, no alpha)"
