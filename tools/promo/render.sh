#!/bin/zsh
# Renders the promo video from the app's own views: ./tools/promo/render.sh [times]
# With times (e.g. 3.0,7.5) it writes PNG stills of those moments instead of the video.
# Needs the Ventura Graphic wallpaper: System Settings → Wallpaper → Ventura Graphic (downloads it).
set -e
HERE=${0:A:h}
REPO=${HERE:h:h}
OUT=$REPO/build/promo
VENTURA="$HOME/Library/Application Support/com.apple.mobileAssetDesktop/Ventura Graphic.heic"
[[ -f $VENTURA ]] || { echo "Ventura Graphic wallpaper not found. Pick it once in System Settings → Wallpaper."; exit 1; }

rm -rf $OUT/src && mkdir -p $OUT/src $REPO/docs/promo
cp -R $REPO/Sources/ $OUT/src/
cd $OUT/src
# Offscreen renders show nothing inside a ScrollView.
sed -i '' 's/ScrollView(showsIndicators: false)/VStack(alignment: .leading)/' Settings.swift
python3 - <<'PY'
s = open('main.swift').read()
s = s[:s.rindex('let app = NSApplication.shared')] + 'MainActor.assumeIsolated { run() }\n'
s = s.replace('    func layout(_ s: WidgetSize)', '    public func layout(_ s: WidgetSize)')
assert 'var showControls: Bool { forceLarge || hovering }' in s
s = s.replace('var showControls: Bool { forceLarge || hovering }', 'var showControls: Bool { forceLarge || hovering || promoHover }')
open('main.swift', 'w').write(s)
PY
cp $HERE/Promo.swift .
swiftc -O -swift-version 5 -target arm64-apple-macos26 *.swift Core/*.swift -o $OUT/promo
swiftc -O $HERE/check.swift -o $OUT/check
[[ -f $OUT/ventura.png ]] || sips -s format png -Z 2400 "$VENTURA" --out $OUT/ventura.png >/dev/null

cd $OUT
if [[ -n $1 ]]; then
  $OUT/promo $REPO/docs/images/icon.png x.mp4 "$1" $OUT/ventura.png $OUT/ventura.png
  echo "Stills in $OUT"
else
  $OUT/promo $REPO/docs/images/icon.png $REPO/docs/promo/Claude-Usage-promo.mp4 "" $OUT/ventura.png $OUT/ventura.png | tail -1
  $OUT/check $REPO/docs/promo/Claude-Usage-promo.mp4
fi
