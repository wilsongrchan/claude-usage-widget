# Prepares the README source images from the 2026-11-15 screenshots: removes the transient
# "Updates paused" line, and crops every widget with the same even margin.
# Run from docs/images: python3 ../../tools/readme/prep_2026-11-15.py ../../tools/readme
# (Kept as a worked example: the screenshot names and pixel rows are specific to that batch.)
import sys
sys.path.insert(0, sys.argv[1])
import numpy as np
from PIL import Image
from cutout import rim_box

SHOT = "Screenshot 2026-11-15 at {}.png".format
M = 18   # margin around every widget, in screenshot pixels (2x)


def arr(path):
    return np.asarray(Image.open(path).convert("RGBA")).astype(float)


def blend_out(a, y0, y1, x0, x1):
    """Replace rows y0..y1 (inclusive) between x0..x1 with a per-column blend of the clean rows
    just above and below: the glass is a smooth gradient there, so the text disappears cleanly."""
    top, bot = a[y0 - 1, x0:x1 + 1], a[y1 + 1, x0:x1 + 1]
    n = y1 - y0 + 2
    for i, y in enumerate(range(y0, y1 + 1), start=1):
        t = i / n
        a[y, x0:x1 + 1] = top * (1 - t) + bot * t


def even_crop(a, box, m=M):
    x0, y0, x1, y1 = box
    return Image.fromarray(a[y0 - m:y1 + 1 + m, x0 - m:x1 + 1 + m].clip(0, 255).astype(np.uint8))


# ---- large: remove "Updates paused · retrying in 59s" (rows 131-151)
large = arr(SHOT("23.56.46"))
blend_out(large, 127, 156, 40, 470)
even_crop(large, rim_box(Image.open(SHOT("23.56.46")))).save("large.png")

# ---- medium: "Updates paused" -> "Updated just now", the text taken from the clean large shot
med = arr(SHOT("23.40.00"))
blend_out(med, 107, 135, 50, 262)
src = arr(SHOT("23.40.47"))
sy0, sy1, sx0, sx1 = 103, 128, 52, 232          # "Updated just now" plus a little room
bg = np.empty_like(src[sy0:sy1 + 1, sx0:sx1 + 1])
for i in range(sy1 - sy0 + 1):                  # the glass behind the text in the source
    t = (i + 1) / (sy1 - sy0 + 2)
    bg[i] = src[sy0 - 1, sx0:sx1 + 1] * (1 - t) + src[sy1 + 1, sx0:sx1 + 1] * t
dy = 113 - 106                                  # line up the cap tops ("U")
med[sy0 + dy:sy1 + dy + 1, sx0:sx1 + 1, :3] += (src[sy0:sy1 + 1, sx0:sx1 + 1] - bg)[..., :3]
even_crop(med, rim_box(Image.open(SHOT("23.40.00")))).save("medium.png")

# ---- small (as taken) and the monochrome small (archived 2026-11-13 shot, 1x -> 2x)
even_crop(arr(SHOT("23.40.08")), rim_box(Image.open(SHOT("23.40.08")))).save("small.png")
mono = Image.open("archive/small-mono.png").convert("RGBA")
mono = mono.resize((mono.width * 2, mono.height * 2), Image.LANCZOS)
even_crop(np.asarray(mono).astype(float), rim_box(mono)).save("small-mono.png")

# ---- settings tabs: all the same size, widget centred
for name, t in [("rings", "23.57.13"), ("widget", "23.47.50"), ("alerts", "23.47.28"), ("data", "23.47.59")]:
    im = Image.open(SHOT(t))
    even_crop(arr(SHOT(t)), rim_box(im)).save(f"settings-{name}.png")

# ---- menu bar popover: remove the paused line, keep the menu bar on top, even sides and bottom
pop = arr(SHOT("23.57.03"))
blend_out(pop, 181, 210, 90, 480)
L = (pop[..., :3].mean(axis=2))
row = L[450]                                    # through the rings: white popover vs. wallpaper
inside = np.where(row > 235)[0]
px0, px1 = inside.min(), inside.max()
col = L[:, (px0 + px1) // 2]
py1 = int(np.where(col > 235)[0].max())         # last white row, scanning the centre column: the popover's bottom
side = 40                                       # wallpaper margin left, right and below
Image.fromarray(pop[0:py1 + 1 + side, px0 - side:px1 + 1 + side].clip(0, 255).astype(np.uint8)).save("menubar.png")
print("popover", px0, px1, py1)

# ---- desktop column: native widgets + ours (faded). Rims measured at x 42-729, y 52-1459
# (688 wide = two native columns); 22px margin all round, as before.
d = arr(SHOT("23.46.53"))
x0, y0, x1, y1 = 42, 52, 729, 1459
Image.fromarray(d[y0 - 22:y1 + 23, x0 - 22:x1 + 23].clip(0, 255).astype(np.uint8)).save("desktop.png")
