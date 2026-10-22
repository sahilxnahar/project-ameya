#!/bin/sh
# Renders Ameya's icons from the brand mark (Resources/Brand/ameya-mark.svg):
#   Resources/Brand/MenuBarLogo.png, MenuBarLogo@2x.png   the full mark as a menu bar template (black + alpha)
#   Resources/AppIcon.icns                                 the app icon, every size, via iconutil
#   docs/screenshots/app-icon.png                          a 512 px preview for the README
# The outputs are committed, so building the app doesn't need these tools.
# Needs: rsvg-convert and magick (Homebrew: librsvg, imagemagick), iconutil (Xcode tools).
set -eu

cd "$(dirname "$0")/.."
MARK=Resources/Brand/ameya-mark.svg
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for tool in rsvg-convert magick iconutil; do
    command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done

# A black copy of the mark: menu bar templates take only the alpha channel.
sed 's/#C9A95D/#000000/g' "$MARK" > "$WORK/black.svg"

# Menu bar: 18 pt, with a 1 pt margin so the mark sits optically centred among other icons.
rsvg-convert -w 16 -h 16 "$WORK/black.svg" -o "$WORK/m16.png"
rsvg-convert -w 32 -h 32 "$WORK/black.svg" -o "$WORK/m32.png"
magick -size 18x18 xc:none "$WORK/m16.png" -gravity center -composite Resources/Brand/MenuBarLogo.png
magick -size 36x36 xc:none "$WORK/m32.png" -gravity center -composite Resources/Brand/MenuBarLogo@2x.png

# App icon, on Apple's 1024 grid: an 824 pt rounded square (radius 185) with a soft shadow,
# a warm near-black gradient, a hairline gold rim, and the mark in a gold gradient.
S=1024
magick -size 824x824 gradient:'#2E271D'-'#110E0A' "$WORK/plate.png"
magick -size 824x824 xc:none -fill white -draw "roundrectangle 0,0 823,823 185,185" "$WORK/round.png"
magick "$WORK/plate.png" "$WORK/round.png" -alpha off -compose CopyOpacity -composite "$WORK/plate-round.png"
magick -size 824x824 xc:none -fill none -stroke '#C9A95D59' -strokewidth 4 \
    -draw "roundrectangle 3,3 820,820 183,183" "$WORK/rim.png"
rsvg-convert -w 540 -h 540 "$WORK/black.svg" -o "$WORK/mark-mask.png"
magick -size 540x540 gradient:'#EED79A'-'#B38D3F' "$WORK/gold.png"
magick "$WORK/gold.png" \( "$WORK/mark-mask.png" -alpha extract \) -alpha off -compose CopyOpacity -composite "$WORK/mark-gold.png"
magick -size ${S}x${S} xc:none \
    \( "$WORK/plate-round.png" -background black -shadow 40x14+0+12 \) -gravity center -geometry +0+6 -composite \
    "$WORK/plate-round.png" -gravity center -composite \
    "$WORK/rim.png" -gravity center -composite \
    "$WORK/mark-gold.png" -gravity center -composite \
    "$WORK/icon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    magick "$WORK/icon-1024.png" -resize ${size}x${size} "$ICONSET/icon_${size}x${size}.png"
    double=$((size * 2))
    magick "$WORK/icon-1024.png" -resize ${double}x${double} "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
magick "$WORK/icon-1024.png" -resize 512x512 docs/screenshots/app-icon.png
echo "Rendered Resources/Brand/MenuBarLogo*.png, Resources/AppIcon.icns, docs/screenshots/app-icon.png"
