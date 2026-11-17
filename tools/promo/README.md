# Promo video

A 20-second promo (1280×720, 60 fps, no sound) rendered from the app's own SwiftUI views,
frame by frame, and written to MP4 with AVFoundation. No screen recording, no editor.

```zsh
./tools/promo/render.sh            # → docs/promo/Claude-Usage-promo.mp4 (not in git)
./tools/promo/render.sh 3.0,7.5    # PNG stills of those moments → build/promo/
```

Needs the **Ventura Graphic** wallpaper on this Mac: pick it once in System Settings → Wallpaper,
which downloads it (you can switch back afterwards).

- `Promo.swift`: the scenes and timeline. Times inside scenes are *scene time*; `holds` stretch
  quiet moments (and one skip) to give *video time*, so pops and clicks keep their speed.
- `render.sh`: copies `Sources/`, patches two things for offscreen rendering (ScrollView → VStack,
  a switch to show the hover controls), builds and runs it.
- `check.swift`: prints the file's duration, size and frame rate and saves a few frames.

Scenes: title → rings fill and time-lapse with a slow push-in → the session ring floods the screen
orange → Ventura desktop: large → medium → small, then monochrome → alert and menu bar popover → end card.
The other desktop widgets are generic stand-ins (no real app's design or branding).
