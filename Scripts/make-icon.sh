#!/usr/bin/env bash
#
# Builds Assets/Memoir.icns from Assets/memoir-mark.svg.
#
# Run by hand when the mark changes, not by build-app.sh. The .icns is committed, so the
# app build stays a copy rather than a render: this script depends on QuickLook's SVG
# support, which is not a thing to put on the path between a clean checkout and a signed
# bundle. `make-icon.sh && git add Assets/Memoir.icns` is the whole workflow.
#
# The mark is the single source. Padding and sizes are computed here rather than kept as a
# second, hand-drawn SVG, because two copies of a logo drift the same way two copies of a
# tool list do, and the one that is wrong is always the one nobody is looking at.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARK="$ROOT/Assets/memoir-mark.svg"
OUT="$ROOT/Assets/Memoir.icns"

[[ -f "$MARK" ]] || { echo "no mark at $MARK" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Memoir.iconset"
mkdir -p "$ICONSET"

# Everything between the opening <svg> and the closing tag: the drawing, without the source
# file's own canvas. Extracted rather than duplicated so the mark stays the one place the
# shapes are written down.
BODY="$(sed -n '/<svg[^>]*>/,/<\/svg>/p' "$MARK" | sed '1d;$d')"
[[ -n "${BODY//[[:space:]]/}" ]] || { echo "could not read any shapes out of $MARK" >&2; exit 1; }

# The mark is a 240-unit disc on a 256 canvas, very nearly full bleed. macOS icons sit on a
# grid with real margin around them, and an icon drawn edge to edge reads as oversized beside
# every other icon in the Dock and in System Settings. 300 puts the disc at 80% of the canvas,
# which is where Apple's own circular marks land.
CANVAS=300
INSET=22

render() { # size, destination
    local size="$1" dest="$2"
    # width/height are in the *viewBox's* units, not pixels, and `-s` does the scaling.
    # Setting them to the pixel size instead leaves QuickLook framing a 300-unit drawing on a
    # canvas it sized from a different number, and the mark lands off-centre with margin on
    # two sides, which looks enough like a design choice to survive a glance.
    cat > "$WORK/frame.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$CANVAS" height="$CANVAS" viewBox="0 0 $CANVAS $CANVAS" fill="none">
  <g transform="translate($INSET,$INSET)">
$BODY
  </g>
</svg>
SVG
    rm -f "$WORK/frame.svg.png"
    qlmanage -t -s "$size" -o "$WORK" "$WORK/frame.svg" >/dev/null 2>&1
    [[ -f "$WORK/frame.svg.png" ]] || { echo "QuickLook rendered nothing at ${size}px" >&2; exit 1; }
    # QuickLook fits to the longest edge and can come back a pixel short on some sizes; the
    # iconset is rejected wholesale if any member is off, so pin the dimensions.
    sips -z "$size" "$size" "$WORK/frame.svg.png" --out "$dest" >/dev/null
}

echo "==> Rendering from $(basename "$MARK")"
for pair in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $pair
    render "$1" "$ICONSET/$2.png"
    echo "  $2.png (${1}px)"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
