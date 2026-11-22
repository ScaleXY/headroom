#!/usr/bin/env python3
"""Builds the marketing site's images in site/public/ from the app's own fixture renders.

1. `HeadroomApp --render all` draws every UI state offscreen with demo data (never live data).
2. The dark renders the page uses are converted to WebP as they are, under site/public/img/.
3. The Mac App Store screenshots in appstore/screenshots/2880x1800/ (run `make appstore` first)
   become the highlights gallery in img/store/, at 1200 and 2400 px wide, and the first one is
   cut down to og.jpg, the link preview.
4. `HeadroomWidgetPreview --mobile` draws the iPhone and Watch run screens for img/widgets/.

The other images in img/widgets/ (desktop widgets, Lock Screen, complications, the session Live
Activity) are hand-cropped from `HeadroomWidgetPreview` and aren't rebuilt here.

Run with `make site-media` (needs cwebp and ImageMagick: brew install webp imagemagick).
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PUBLIC = ROOT / "site/public"
IMG = PUBLIC / "img"
STORE = ROOT / "appstore/screenshots/2880x1800"

# Site image name -> fixture render (dark). The page loads these as /img/<name>.webp.
RENDERS = {
    "pace-mockup": "pace-mockup-dark", "pace-plenty": "pace-plenty-dark", "pace-onpace": "pace-onpace-dark",
    "pace-tight": "pace-tight-dark", "pace-verytight": "pace-verytight-dark",
    "activity-all-7d": "activity-all-7d-dark", "share-card-claude": "share-card-claude",
    "settings-2": "settings-2-dark", "onboarding-3": "onboarding-3-dark",
    # Agent runs: the list as it leads (a question, your turn, the day's receipt), and a run's page
    # in the states the page walks through.
    "runs-needs-you": "runs-mixed-dark", "runs-your-turn": "runs-your-turn-dark", "runs-day": "runs-settled-dark",
    "runpage-question": "runpage-input-1-briefing-dark", "runpage-briefing": "runpage-mixed-4-briefing-dark",
    "runpage-lanes": "runpage-timeline-1-lanes-dark", "runpage-limit": "runpage-limit-1-briefing-dark",
    "runpage-finished": "runpage-finished-1-briefing-dark",
}
# Cut from a render: site name -> (render, magick geometry to keep, size it fills). The 5-hour
# sessions tile shows the Limits chart's session lane, from the legend to the stat row.
CROPS = {
    "sessions": ("pace-limits-session-dark", "768x642+0+398", (768, 660)),
    # The 5-hour section's states: the Limits card from its top, below the popover's header; the
    # page fades its foot out.
    **{f"limits-{s}": (f"pace-limits-{s}-dark", "768x1150+0+96", (768, 1150)) for s in ("session", "runsout", "amber", "blocked", "daily")},
}
# Menu bar items, drawn on a transparent background.
STATUS_ITEMS = ["default", "percent", "session", "tighter", "urgent", "runs-one", "runs-several", "runs-input", "runs-quiet"]
# iPhone and Watch run screens: site name -> (preview file, crop as "WxH+X+Y" or None for all of it).
MOBILE = {
    "iphone-runs": ("mobile-runs-names-fill-dark", None),
    "watch-run": ("mobile-watch-runpage-names-0", None),
    "live-activity-run": ("mobile-liveactivity-runs-names", "736x300+48+46"),
}


def run(cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def webp(src, out, quality=86, resize=None):
    cmd = ["cwebp", "-quiet", "-q", str(quality), "-alpha_q", "100", "-m", "6"]
    if resize:
        cmd += ["-resize", str(resize[0]), str(resize[1])]
    run(cmd + [str(src), "-o", str(out)])
    print(f"  {out.relative_to(ROOT)}")


def main():
    for tool in ("cwebp", "magick"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is needed for the site images (brew install webp imagemagick).")
    slides = sorted(STORE.glob("*.png"))
    if not slides:
        sys.exit("Run `make appstore` first: the highlights gallery is built from its screenshots.")
    run(["swift", "build", "--product", "HeadroomApp"], cwd=ROOT, stdout=subprocess.DEVNULL)
    run(["swift", "build", "--product", "HeadroomWidgetPreview"], cwd=ROOT, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory() as tmp:
        raw, mobile = Path(tmp) / "raw", Path(tmp) / "mobile"
        run([str(ROOT / ".build/debug/HeadroomApp"), "--render", "all", "--out", str(raw)], stdout=subprocess.DEVNULL)
        run([str(ROOT / ".build/debug/HeadroomWidgetPreview"), str(mobile), "--mobile"], stdout=subprocess.DEVNULL)
        print("Writing site/public/")

        for name, render in RENDERS.items():
            webp(raw / f"{render}.png", IMG / f"{name}.webp")
        for name, (render, geometry, (w, h)) in CROPS.items():
            cut = Path(tmp) / f"{name}.png"
            run(["magick", str(raw / f"{render}.png"), "-crop", geometry, "+repage", "-filter", "Lanczos",
                 "-resize", f"{w}x{h}^", "-gravity", "center", "-crop", f"{w}x{h}+0+0", "+repage", str(cut)])
            webp(cut, IMG / f"{name}.webp")
        for item in STATUS_ITEMS:
            webp(raw / f"statusitem-{item}-dark.png", IMG / f"statusitem-{item}.webp", quality=90)

        for name, (preview, crop) in MOBILE.items():
            src = mobile / f"{preview}.png"
            if crop:
                cut = Path(tmp) / f"{name}.png"
                run(["magick", str(src), "-crop", crop, "+repage", str(cut)])
                src = cut
            webp(src, IMG / "widgets" / f"{name}.webp", quality=90)

        # The highlights gallery, replaced as a set so a renamed slide leaves nothing behind.
        shutil.rmtree(IMG / "store", ignore_errors=True)
        (IMG / "store").mkdir(parents=True)
        for slide in slides:
            for width in (1200, 2400):
                webp(slide, IMG / "store" / f"{slide.stem}-{width}.webp", quality=82, resize=(width, width * 5 // 8))

        # The link preview: the hero slide, cut to 1200 x 630 around its headline and popover.
        run(["magick", str(slides[0]), "-resize", "1200x750", "-crop", "1200x630+0+44", "+repage",
             "-quality", "84", str(PUBLIC / "og.jpg")])
        print("  site/public/og.jpg")


if __name__ == "__main__":
    main()
