#!/usr/bin/env python3
"""Builds the marketing site's images in site/public/ from the app's own fixture renders.

1. `HeadroomApp --render all` draws every UI state offscreen with demo data (never live data).
2. The dark renders the page uses are converted to WebP as they are, under site/public/img/.
3. The first Mac App Store screenshot in appstore/screenshots/2880x1800/ (run `make appstore`
   first) is cut down to og.jpg, the link preview.
4. `HeadroomWidgetPreview --mobile` draws the iPhone and Watch run screens for img/widgets/.
5. The screens the page shows inside its device frames go to img/dev/: iPhone, iPad and Watch
   screenshots from appstore/mobile/1-normal/ (made by `make mobile-appstore`), and the iPhone
   Limits card in each pacing state, set under a real screenshot's status and navigation bars.

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

# Screens for the page's device frames: site name -> (App Store folder, screenshot, width to scale to).
SHOTS = ROOT / "appstore/mobile/1-normal"
IPHONE, IPAD, WATCH = "iphone-dynamic-island-medium-1206x2622", "ipad-13-inch-2752x2064", "watch-ultra-4-422x514"
DEVICE_SHOTS = {
    "iphone-now": (IPHONE, "01-now", 603), "iphone-session": (IPHONE, "03-session", 603),
    "iphone-burn": (IPHONE, "04-burn", 603), "iphone-activity": (IPHONE, "06-activity", 603),
    "iphone-light": (IPHONE, "10-light", 603),
    "ipad-now": (IPAD, "01-now", 1376), "ipad-activity": (IPAD, "06-activity", 1376), "ipad-light": (IPAD, "10-light", 1376),
    "watch-plenty": (WATCH, "06-plenty", 422), "watch-ontrack": (WATCH, "08-on-pace", 422),
    "watch-tight": (WATCH, "05-week", 422), "watch-verytight": (WATCH, "07-tight", 422),
    "watch-session": (WATCH, "01-session", 422), "watch-warning": (WATCH, "02-warning", 422),
    "watch-paused": (WATCH, "03-paused", 422), "watch-sessions": (WATCH, "09-sessions", 422),
}
# The iPhone Limits card in each pacing state: site name -> (card render, the screenshot whose
# status and navigation bars sit above it, which names the same tool).
IPHONE_STATES = {
    "iphone-plenty": ("mobile-screen-limits-plenty-dark", "03-session"),
    "iphone-ontrack": ("mobile-screen-limits-ontrack-dark", "02-pace"),
    "iphone-tight": ("mobile-screen-limits-tight-dark", "03-session"),
    "iphone-verytight": ("mobile-screen-limits-verytight-dark", "02-pace"),
}


def run(cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def webp(src, out, quality=86, resize=None):
    cmd = ["cwebp", "-quiet", "-q", str(quality), "-alpha_q", "100", "-m", "6"]
    if resize:
        cmd += ["-resize", str(resize[0]), str(resize[1])]
    run(cmd + [str(src), "-o", str(out)])
    print(f"  {out.relative_to(ROOT)}")


def device_screens(mobile, tmp):
    """Writes img/dev/: the screens the page sets inside its iPhone, iPad and Watch frames."""
    dev = IMG / "dev"
    dev.mkdir(parents=True, exist_ok=True)
    for name, (folder, shot, width) in DEVICE_SHOTS.items():
        src = SHOTS / folder / f"{shot}.png"
        if not src.exists():
            sys.exit(f"{src.relative_to(ROOT)} is missing: run `make mobile-appstore` first.")
        small = Path(tmp) / f"{name}.png"
        run(["magick", str(src), "-filter", "Lanczos", "-resize", f"{width}x", str(small)])
        webp(small, dev / f"{name}.webp", quality=84)
    # A screenshot is 1206 px wide with its card 1112 px wide at (47, 396); the render's card is
    # 716 px wide inside a 32 px margin. The page color fills the rest of the screen.
    for name, (render, chrome) in IPHONE_STATES.items():
        out = Path(tmp) / f"{name}.png"
        run(["magick", "-size", "1206x2622", "xc:rgb(20,22,25)",
             "(", str(SHOTS / IPHONE / f"{chrome}.png"), "-crop", "1206x380+0+0", "+repage", ")", "-geometry", "+0+0", "-composite",
             "(", str(Path(mobile) / f"{render}.png"), "-shave", "32x32", "-filter", "Lanczos", "-resize", "1112x", ")",
             "-geometry", "+47+396", "-composite", "-filter", "Lanczos", "-resize", "603x", str(out)])
        webp(out, dev / f"{name}.webp", quality=84)


def main():
    for tool in ("cwebp", "magick"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is needed for the site images (brew install webp imagemagick).")
    slides = sorted(STORE.glob("*.png"))
    if not slides:
        sys.exit("Run `make appstore` first: the link preview is cut from its first screenshot.")
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
        device_screens(mobile, tmp)

        # The link preview: the hero slide, cut to 1200 x 630 around its headline and popover.
        run(["magick", str(slides[0]), "-resize", "1200x750", "-crop", "1200x630+0+44", "+repage",
             "-quality", "84", str(PUBLIC / "og.jpg")])
        print("  site/public/og.jpg")


if __name__ == "__main__":
    main()
