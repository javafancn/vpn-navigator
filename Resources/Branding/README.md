# VPN Navigator branding

`AppIcon.svg` is the supplied design, preserved byte for byte. `AppIcon.png`
is its transparent 1024-pixel raster; `AppIcon.icns` contains standard and Retina
sizes. The application bundle declares the ICNS in `CFBundleIconFile`. All
in-app brand marks use the PNG, compatible with macOS 13.

`StatusIcon.svg` extracts the navigation arrow and route loop as a monochrome
mark without the tile. Its vector PDF is drawn into a template menu-bar image
alongside live download/upload text; macOS supplies the appropriate tint.
No wallpaper or application surface is part of these assets.

Regenerate from this directory with Inkscape and Pillow (development tools only;
normal builds copy the checked-in assets and need neither dependency):

```sh
inkscape AppIcon.svg --export-type=png --export-filename=AppIcon.png --export-width=1024
inkscape StatusIcon.svg --export-type=pdf --export-filename=StatusIcon.pdf
python3 - <<'PY'
from PIL import Image
Image.open('AppIcon.png').convert('RGBA').save(
    'AppIcon.icns', sizes=[(16,16), (32,32), (64,64), (128,128),
                         (256,256), (512,512), (1024,1024)])
PY
```

The bundle self-test verifies resource decoding; visual acceptance on a physical
Mac still checks Dock scaling, light/dark menu bars and available notch space.
