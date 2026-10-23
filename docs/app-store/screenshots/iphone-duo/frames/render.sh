#!/bin/zsh
# Renders frames.html into the iPhone Duo App Store set (2007 x 2853, no alpha).
# Usage: docs/app-store/screenshots/iphone-duo/frames/render.sh
set -e
here=${0:A:h}
out=${here:h}
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
names=(01-laptop 02-folded 03-devices 04-windows-pc 05-files)
for i in {1..5}; do
  png=$out/$names[$i].png
  "$chrome" --headless=new --hide-scrollbars --force-device-scale-factor=1 --window-size=2007,2853 \
    --virtual-time-budget=3000 --screenshot=$png "file://$here/frames.html#$i" 2>/dev/null
  # App Store Connect rejects alpha; headless Chrome writes opaque PNGs, which this line confirms.
  sips -g pixelWidth -g pixelHeight -g hasAlpha $png | tail -3 | tr '\n' ' '; echo " $names[$i]"
done
