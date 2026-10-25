#!/usr/bin/env python3
"""Draws the DMG window background into assets/dmg-background.tiff.

The page is captured with headless Chrome at 1x and 2x, and the two PNGs are combined into one
HiDPI TIFF so Finder picks the sharp one on Retina screens. The layout matches the icon positions
in Packaging/dmg_settings.py: Headroom.app at (170, 210) and Applications at (470, 210), 128 pt icons,
with each icon and its Finder label sitting in a soft well.

Run with `make dmg-background` (needs Google Chrome). The TIFF is committed, so `make dmg` doesn't.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "dmg-background.tiff"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WIDTH, HEIGHT = 640, 400
APP_X, APPS_X, ICON_Y = 170, 470, 210

AZURE = "#4A8EFF"
INK = "#1D1E23"
MUTED = "#7C7F88"


def meter_arrow():
    """The track between the two icons: meter cells filling up toward Applications."""
    cells = []
    x, step = 262, 22
    for i, opacity in enumerate((.16, .3, .5, .75, 1)):
        cells.append(f'<rect x="{x + i * step}" y="-4" width="14" height="8" rx="3.4" fill="{AZURE}" opacity="{opacity}"/>')
    tip = x + 5 * step + 2
    chevron = (f'<path d="M{tip} -8 L{tip + 8} 0 L{tip} 8" fill="none" stroke="{AZURE}" '
               f'stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>')
    return (f'<svg width="{WIDTH}" height="20" viewBox="0 -10 {WIDTH} 20" '
            f'style="position:absolute;left:0;top:{ICON_Y - 10}px">{"".join(cells)}{chevron}</svg>')


def page():
    icon = (ROOT / "assets" / "icon.svg").read_text()
    icon = icon.replace("<svg ", '<svg width="22" height="22" ', 1)
    well = ("position:absolute;top:{top}px;left:{left}px;width:176px;height:196px;border-radius:36px;"
            "background:linear-gradient(180deg,rgba(255,255,255,.75),rgba(255,255,255,.35));"
            "box-shadow:inset 0 0 0 1px rgba(20,22,30,.06),0 1px 2px rgba(20,22,30,.04),0 10px 30px rgba(20,22,30,.05)")
    wells = "".join(f'<div style="{well.format(top=ICON_Y - 86, left=x - 88)}"></div>' for x in (APP_X, APPS_X))
    return f"""<!doctype html><meta charset=utf-8><style>
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{ width: {WIDTH}px; height: {HEIGHT}px; position: relative; overflow: hidden;
  font-family: -apple-system, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing: antialiased;
  background: radial-gradient(90% 70% at 50% 0%, #FFFFFF 0%, rgba(255,255,255,0) 70%), linear-gradient(180deg, #F6F6F8, #EBEBEF); }}
.brand {{ position: absolute; top: 34px; left: 0; right: 0; display: flex; justify-content: center; align-items: center; gap: 9px;
  font: 600 15px/1 -apple-system, "SF Pro Display", system-ui; letter-spacing: -.01em; color: {INK}; }}
.brand svg {{ border-radius: 6px; box-shadow: 0 1px 3px rgba(0,0,0,.18); }}
.hint {{ position: absolute; bottom: 38px; left: 0; right: 0; text-align: center; font-size: 12.5px; color: {MUTED}; }}
.hint b {{ font-weight: 600; color: {INK}; }}
</style><body>
<div class="brand">{icon}Headroom</div>
{wells}
{meter_arrow()}
<div class="hint">Drag <b>Headroom</b> onto <b>Applications</b> to install</div>
</body>"""


def capture(html_path, out, scale):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--force-device-scale-factor={scale}",
                    f"--window-size={WIDTH},{HEIGHT}", f"--screenshot={out}", html_path.as_uri()],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    if not Path(CHROME).exists():
        sys.exit("Google Chrome is needed to draw the DMG background.")
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        html_path = work / "background.html"
        html_path.write_text(page())
        one, two = work / "background.png", work / "background@2x.png"
        capture(html_path, one, 1)
        capture(html_path, two, 2)
        # Mark the 2x image as 144 dpi so tiffutil pairs it with the 72 dpi one.
        subprocess.run(["sips", "-s", "dpiWidth", "144", "-s", "dpiHeight", "144", str(two)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(OUT)], check=True)
    print(OUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
