#!/usr/bin/env python3
"""Builds the Mac App Store assets in appstore/ from the app's own fixture renders.

1. `HeadroomApp --render all` draws every UI state offscreen with demo data (never live data).
2. Each screenshot is laid out once as a 1440-pt-wide HTML page.
3. Headless Chrome captures it twice:
   - screenshots/2880x1800/  16:10 at 2x, the size App Store Connect accepts for Mac screenshots;
   - screenshots/1920x1080/  16:9 at 1.333x, the 1080p set (also the frames of the app preview).
4. ffmpeg joins the 1080p frames into preview/headroom-preview-1920x1080.mp4 (H.264, 30 fps, silent AAC).
5. icon/headroom-icon-1024.png is rendered from assets/icon.svg.

Run with `make appstore` (needs Google Chrome and ffmpeg; rsvg-convert, ImageMagick and pngquant are optional).
"""
import html
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "appstore"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

W = 1440
SIZES = [("2880x1800", 900, 2), ("1920x1080", 810, 4 / 3)]

INK = "#F4F4F6"
MUTED = "rgba(244,244,246,.66)"
STATE = {"plenty": "#6AA8FF", "onpace": "#ECEDF1", "tight": "#FFC248", "verytight": "#FF6982"}
CLAUDE = "#D97757"
CODEX = "#10A37F"

# Desktop wallpapers: a dark base with glows in the brand and pacing colors.
WALLS = {
    "hero": f"radial-gradient(55% 75% at 92% 8%, rgba(74,142,255,.45), transparent 70%),"
            f"radial-gradient(50% 70% at 0% 100%, rgba(217,119,87,.38), transparent 70%),"
            f"radial-gradient(45% 60% at 60% 115%, rgba(16,163,127,.32), transparent 70%),"
            f"linear-gradient(160deg, #141833, #0C0E18 60%, #0A1A24)",
    "blue": "radial-gradient(60% 80% at 50% -10%, rgba(74,142,255,.34), transparent 70%),"
            "radial-gradient(40% 50% at 100% 100%, rgba(106,168,255,.16), transparent 70%),"
            "linear-gradient(180deg, #10142A, #0B0C14)",
    "amber": "radial-gradient(50% 70% at 0% 0%, rgba(255,194,72,.26), transparent 70%),"
             "radial-gradient(45% 60% at 100% 100%, rgba(255,105,130,.22), transparent 70%),"
             "linear-gradient(170deg, #1A1510, #0D0C10 55%, #130C12)",
    "violet": "radial-gradient(55% 75% at 100% 0%, rgba(140,110,255,.30), transparent 70%),"
              "radial-gradient(50% 70% at 0% 100%, rgba(74,142,255,.22), transparent 70%),"
              "linear-gradient(160deg, #15122B, #0C0C16)",
    "green": "radial-gradient(55% 70% at 100% 10%, rgba(16,163,127,.30), transparent 70%),"
             "radial-gradient(50% 70% at 0% 100%, rgba(217,119,87,.26), transparent 70%),"
             "linear-gradient(160deg, #0E1A18, #0B0D10 60%)",
    "light": "radial-gradient(60% 70% at 92% 10%, rgba(100,168,255,.50), transparent 70%),"
             "radial-gradient(55% 65% at 0% 100%, rgba(240,160,132,.50), transparent 70%),"
             "radial-gradient(50% 60% at 55% 115%, rgba(63,208,163,.38), transparent 70%),"
             "linear-gradient(160deg, #E6ECF8, #F3EEF2 60%, #E4F0EC)",
}

BASE_CSS = f"""
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
html, body {{ background: #0B0C10; overflow: hidden; }}
body {{ font-family: -apple-system, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing: antialiased; color: {INK}; }}
.slide {{ position: relative; width: {W}px; overflow: hidden; }}
.copy {{ position: absolute; }}
.copy.top {{ left: 0; right: 0; text-align: center; }}
.copy.top p {{ margin-left: auto; margin-right: auto; max-width: 860px; }}
.eyebrow {{ display: inline-flex; align-items: center; gap: 10px; font: 600 14px/1 ui-monospace, "SF Mono", Menlo, monospace;
  letter-spacing: .16em; text-transform: uppercase; color: rgba(244,244,246,.56); }}
.eyebrow i {{ width: 8px; height: 8px; border-radius: 50%; }}
h1 {{ margin-top: 20px; font: 800 60px/1.02 -apple-system, "SF Pro Display", system-ui; letter-spacing: -.035em; }}
.copy p {{ margin-top: 18px; font: 400 21px/1.45 -apple-system, system-ui; color: {MUTED}; max-width: 620px; }}
.copy.left p {{ max-width: 460px; }}
.fit {{ position: absolute; transform-origin: 0 0; }}
.label {{ display: flex; align-items: center; gap: 9px; height: 20px; margin: 0 4px 14px;
  font: 600 13px/1 ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: .12em; text-transform: uppercase; color: rgba(244,244,246,.6); }}
.label i {{ width: 8px; height: 8px; border-radius: 50%; flex: none; }}
.shot {{ border-radius: 26px; overflow: hidden; position: relative; }}
.shot img {{ display: block; width: 100%; }}
.pop {{ filter: drop-shadow(0 30px 60px rgba(0,0,0,.55)); }}
.win {{ border-radius: 14px; box-shadow: 0 0 0 1px rgba(255,255,255,.06), 0 30px 70px rgba(0,0,0,.55); }}
.menubar {{ position: absolute; inset: 0 0 auto 0; height: 34px; display: flex; align-items: center; justify-content: flex-end;
  gap: 20px; padding: 0 22px; background: rgba(8,9,16,.42); backdrop-filter: blur(20px); }}
.menubar img {{ height: 24px; }}
.menubar span {{ font: 500 14px -apple-system, system-ui; color: {INK}; opacity: .92; font-variant-numeric: tabular-nums; }}
"""


def run(cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def label(text, color=None):
    dot = f'<i style="background:{color};box-shadow:0 0 12px {color}"></i>' if color else ""
    return f'<div class="label">{dot}{html.escape(text)}</div>'


def crop(src, width, height, fade=0.8, position="top", cls="shot pop"):
    """A popover render `width` css px wide, cropped to `height` with a soft fade at the cut edge."""
    direction = "180deg" if position == "top" else "0deg"
    mask = f"-webkit-mask-image:linear-gradient({direction},#000 {int(fade * 100)}%,transparent)" if fade else ""
    return (f'<div class="{cls}" style="width:{width}px;height:{height}px;{mask}">'
            f'<img src="{src}" style="height:100%;object-fit:cover;object-position:{position}"></div>')


def copy_block(eyebrow, title, sub, accent=None):
    dot = f'<i style="background:{accent};box-shadow:0 0 12px {accent}"></i>' if accent else ""
    return (f'<div class="eyebrow">{dot}{html.escape(eyebrow)}</div>'
            f'<h1>{title}</h1><p>{html.escape(sub)}</p>')


class Slide:
    """One screenshot: a wallpaper, a copy block and a visual scaled to fit the space left."""

    def __init__(self, name, wall, eyebrow, title, sub, visual, vw, vh, layout="top", accent=None, extra=""):
        self.name, self.wall, self.layout, self.extra = name, wall, layout, extra
        self.copy = copy_block(eyebrow, title, sub, accent)
        self.visual, self.vw, self.vh = visual, vw, vh

    def page(self, h):
        if self.layout == "top":
            copy = f'<div class="copy top" style="top:{round(h * .075)}px">{self.copy}</div>'
            box = (80, round(h * .075) + 205, W - 160, h - round(h * .075) - 205 - 44)
        elif self.layout == "free":
            copy = f'<div class="copy left" style="left:100px;top:50%;transform:translateY(-50%);width:500px">{self.copy}</div>'
            return f'<div class="slide" style="height:{h}px;background:{WALLS[self.wall]}">{self.extra}{copy}{self.visual(h)}</div>'
        else:
            copy = f'<div class="copy left" style="left:100px;top:50%;transform:translateY(-50%);width:500px">{self.copy}</div>'
            box = (630, 70, W - 630 - 70, h - 140)
        x, y, bw, bh = box
        s = min(bw / self.vw, bh / self.vh, 1.0)
        left = x + (bw - self.vw * s) / 2
        top = y + (bh - self.vh * s) / 2
        vis = (f'<div class="fit" style="left:{left:.1f}px;top:{top:.1f}px;width:{self.vw}px;height:{self.vh}px;'
               f'transform:scale({s:.4f})">{self.visual}</div>')
        return f'<div class="slide" style="height:{h}px;background:{WALLS[self.wall]}">{self.extra}{copy}{vis}</div>'


def capture(html_body, h, scale, out, work):
    page = work / f"{out.stem}-{h}.html"
    page.write_text(f"<!doctype html><meta charset=utf-8><style>{BASE_CSS}</style><body style='width:{W}px;height:{h}px'>{html_body}</body>")
    run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--force-device-scale-factor={scale}",
         f"--window-size={W},{h}", f"--screenshot={out}", "--allow-file-access-from-files", page.as_uri()],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # App Store Connect rejects screenshots with an alpha channel; flatten to opaque RGB.
    run(["sips", "-s", "format", "jpeg", str(out), "--out", str(out.with_suffix(".jpg"))], stdout=subprocess.DEVNULL)
    run(["sips", "-s", "format", "png", str(out.with_suffix(".jpg")), "--out", str(out)], stdout=subprocess.DEVNULL)
    out.with_suffix(".jpg").unlink()
    w_, h_ = png_size(out)
    expected = (round(W * scale), round(h * scale))
    if (w_, h_) != expected:
        sys.exit(f"{out.name}: got {w_}x{h_}, expected {expected[0]}x{expected[1]}")


def slides(raw):
    hero_extra = f'<div class="menubar"><img src="{raw}/statusitem-dark.png"><span>Tue 10:02</span></div>'

    def hanging_popover(h, scale=1.22):
        # Hangs from the menu bar under the status item and runs off the bottom edge.
        return (f'<div class="fit" style="right:150px;top:44px;transform-origin:100% 0;transform:scale({scale})">'
                f'{crop(f"{raw}/pace-mockup-dark.png", 384, round((h - 44) / scale) + 40, fade=0.9)}</div>')

    # 1. Hero: the popover hanging under its menu bar item.
    hero = Slide("01-hero", "hero", "Headroom for Claude & Codex", "Will this week's<br>allowance last?",
                 "See what's left of your Claude and Codex plans against the time left until they renew, right in your menu bar.",
                 hanging_popover, 0, 0, layout="free", accent=STATE["plenty"], extra=hero_extra)

    # 2. The four pacing states.
    states = [("Plenty", "plenty", STATE["plenty"]), ("On pace", "onpace", STATE["onpace"]),
              ("Getting tight", "tight-projection", STATE["tight"]), ("Very tight", "verytight", STATE["verytight"])]
    cards = "".join(f"<div>{label(t, c)}{crop(f'{raw}/pace-{s}-dark.png', 384, 760, fade=0.8)}</div>" for t, s, c in states)
    pace = Slide("02-pace", "blue", "Pace, not just a percentage", "Use more, keep going, or ease off.",
                 "82% left means little if it renews tomorrow. Headroom weighs what's left against the time left.",
                 f'<div style="display:flex;gap:36px">{cards}</div>', 4 * 384 + 3 * 36, 794, accent=STATE["onpace"])

    # 3. The 5-hour session through its stages.
    levels = [("Not started", "idle", None), ("On track", "comfortable", STATE["onpace"]),
              ("Runs out early", "runsout", STATE["tight"]), ("75% · amber", "amber", STATE["tight"]),
              ("90% · rose", "rose", STATE["verytight"]), ("Paused until reset", "blocked", STATE["verytight"])]
    cell = 384
    row_h = [max(png_size(raw / f"session-{levels[i + j][1]}-dark.png")[1] / 2 for j in range(3)) for i in (0, 3)]
    grid = "".join(f"<div>{label(t, c)}<div class='shot pop'><img src='{raw}/session-{s}-dark.png'></div></div>" for t, s, c in levels)
    session = Slide("03-session", "amber", "5-hour sessions", "The limit you hit first, front and center.",
                    "A forecast for every session, amber from 75%, rose from 90%, and exactly when you're back.",
                    f'<div style="display:grid;grid-template-columns:repeat(3,{cell}px);gap:34px 30px;align-items:start">{grid}</div>',
                    3 * cell + 2 * 30, round(sum(row_h) + 2 * 34 + 34), accent=STATE["tight"])

    # 4. Menu bar meters and their options.
    options = [("Default", "default"), ("With percentages", "percent"), ("Tracks the 5-hour session", "session"),
               ("Whichever is tighter", "tighter"), ("Most urgent only", "urgent")]
    rows = "".join(f"""<div style="margin-bottom:26px">{label(t)}<div style="height:58px;border-radius:16px;overflow:hidden;
        display:flex;align-items:center;justify-content:flex-end;gap:24px;padding:0 24px;
        background:linear-gradient(rgba(8,8,16,.34),rgba(8,8,16,.34)),linear-gradient(115deg,#1A2150,#3B2A5C 55%,#0F2F45);
        box-shadow:0 0 0 1px rgba(255,255,255,.08),0 16px 36px rgba(0,0,0,.4)">
        <img src="{raw}/statusitem-{o}-dark.png" style="height:33px">
        <span style="font:500 18px -apple-system,system-ui,sans-serif;color:#F4F4F6;font-variant-numeric:tabular-nums">Tue 10:02</span>
        </div></div>""" for t, o in options)
    menubar = Slide("04-menubar", "violet", "Your week at a glance", "Five cells.<br>One look.",
                    "Blue means room to spare, white means on pace, amber and rose mean slow down. An hourglass flags allowance about to renew unused.",
                    rows, 640, len(options) * 118 - 26, layout="left", accent=STATE["plenty"])

    # 5. Welcome window: step 3 in front of step 2.
    welcome = Slide("05-welcome", "hero", "Welcome", "Set up in<br>a minute.",
                    "Pick your tools, shape the menu bar and tune the warnings, with a live preview at every step.",
                    f"""<div style="position:relative;width:880px;height:700px">
                      <div class="shot win" style="position:absolute;right:0;top:0;width:640px;opacity:.9"><img src="{raw}/onboarding-2-light.png"></div>
                      <div class="shot win" style="position:absolute;left:0;bottom:0;width:800px"><img src="{raw}/onboarding-3-dark.png"></div></div>""",
                    880, 700, layout="left")

    # 6. Activity: tokens and cost, past weeks, recent sessions.
    activity = Slide("06-activity", "green", "Activity", "See where the tokens go.",
                     "Tokens and cost by hour and by model, every past week, and each recent 5-hour session.",
                     f"""<div style="display:flex;gap:40px">
                       <div>{label("Tokens and cost · 24 hours")}{crop(f'{raw}/activity-all-24h-dark.png', 384, 760, fade=0.88)}</div>
                       <div>{label("Past weeks · 5-hour sessions")}{crop(f'{raw}/activity-all-7d-dark.png', 384, 760, fade=0.88, position='bottom')}</div></div>""",
                     808, 794, accent=CODEX)

    # 7. Settings with its live preview.
    settings = Slide("07-settings", "blue", "Settings", "Every change, previewed live.",
                     "Turn meters and graphs on or off, set the 5-hour warning, and see the card or alert before you leave.",
                     f'<div class="shot win"><img src="{raw}/settings-3-dark.png"></div>', 968, 640)

    # 8. Light and dark.
    themes = Slide("08-appearance", "light", "Light or dark", "Looks at home on any desktop.",
                   "Follows your system appearance, or pick light or dark yourself.",
                   f"""<div style="position:relative;width:820px;height:1100px">
                     <div style="position:absolute;left:0;top:0">{crop(f'{raw}/pace-mockup-light.png', 384, 1040, fade=0.86)}</div>
                     <div style="position:absolute;right:0;top:60px">{crop(f'{raw}/pace-mockup-dark.png', 384, 1040, fade=0.86)}</div></div>""",
                   820, 1100, layout="left")

    # 9. Callouts.
    calls = [("Model cap reached", "cap-empty-dark", STATE["verytight"]), ("Early reset", "early-reset-dark", STATE["plenty"]),
             ("Reset credits expiring", "credits-dark", STATE["tight"])]
    cards = "".join(f"<div>{label(t, c)}{crop(f'{raw}/pace-{s}.png', 384, 560, fade=0.8, position='bottom')}</div>" for t, s, c in calls)
    callouts = Slide("09-callouts", "amber", "No surprises", "Caps, early resets and expiring credits, flagged.",
                     "Know when one model's cap is the one to watch, and use reset credits before they lapse.",
                     f'<div style="display:flex;gap:40px">{cards}</div>', 3 * 384 + 2 * 40, 594, accent=STATE["verytight"])

    return [hero, pace, session, menubar, welcome, activity, settings, themes, callouts]


def light_copy_css(slide):
    """The light wallpaper needs dark copy."""
    if slide.wall != "light":
        return slide
    slide.copy = slide.copy.replace('<h1>', '<h1 style="color:#16171B">').replace('<p>', '<p style="color:rgba(22,23,27,.64)">') \
        .replace('class="eyebrow"', 'class="eyebrow" style="color:rgba(22,23,27,.5)"')
    return slide


def icon(out):
    svg = ROOT / "assets/icon.svg"
    if shutil.which("rsvg-convert") and shutil.which("magick"):
        with tempfile.TemporaryDirectory() as tmp:
            art = Path(tmp) / "art.png"
            run(["rsvg-convert", "-w", "824", "-h", "824", str(svg), "-o", str(art)])
            run(["magick", "-size", "1024x1024", "xc:none", "(", str(art), "-background", "rgba(0,0,0,0.35)", "-shadow", "100x14+0+10", ")",
                 "-gravity", "center", "-geometry", "+0+6", "-composite", str(art), "-gravity", "center", "-composite", str(out)])
    else:
        run(["sips", "-s", "format", "png", "-z", "1024", "1024", str(svg), "--out", str(out)], stdout=subprocess.DEVNULL)


def preview(frames, out, hold=3.4, fade=0.5):
    """A crossfaded slideshow of the 1080p screenshots: H.264 High, 30 fps, with the stereo audio track previews need."""
    inputs = []
    for f in frames:
        inputs += ["-loop", "1", "-t", str(hold), "-framerate", "30", "-i", str(f)]
    n = len(frames)
    graph, last = [], "[0:v]"
    for i in range(1, n):
        tag = f"[x{i}]"
        graph.append(f"{last}[{i}:v]xfade=transition=fade:duration={fade}:offset={i * (hold - fade):.2f}{tag}")
        last = tag
    graph.append(f"{last}format=yuv420p[v]")
    total = n * hold - (n - 1) * fade
    run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-f", "lavfi", "-t", f"{total:.2f}",
         "-i", "anullsrc=channel_layout=stereo:sample_rate=48000", "-filter_complex", ";".join(graph),
         "-map", "[v]", "-map", f"{n}:a", "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-preset", "slow",
         "-b:v", "10M", "-maxrate", "12M", "-bufsize", "24M", "-r", "30", "-c:a", "aac", "-b:a", "256k",
         "-movflags", "+faststart", "-t", f"{total:.2f}", str(out)])
    return total


def main():
    if not Path(CHROME).exists():
        sys.exit("Google Chrome is needed to capture the App Store screenshots.")
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is needed for the app preview (brew install ffmpeg).")
    run(["swift", "build", "--product", "HeadroomApp"], cwd=ROOT, stdout=subprocess.DEVNULL)
    for sub in ("screenshots", "preview", "icon"):
        shutil.rmtree(OUT / sub, ignore_errors=True)
    with tempfile.TemporaryDirectory() as tmp:
        raw, work = Path(tmp) / "raw", Path(tmp) / "pages"
        work.mkdir()
        run([str(ROOT / ".build/debug/HeadroomApp"), "--render", "all", "--out", str(raw)], stdout=subprocess.DEVNULL)
        print("Writing appstore/")
        all_slides = [light_copy_css(s) for s in slides(raw)]
        for size, h, scale in SIZES:
            folder = OUT / "screenshots" / size
            folder.mkdir(parents=True)
            for s in all_slides:
                out = folder / f"{s.name}.png"
                capture(s.page(h), h, scale, out, work)
                print(f"  {out.relative_to(ROOT)}")
    (OUT / "preview").mkdir(parents=True)
    video = OUT / "preview/headroom-preview-1920x1080.mp4"
    seconds = preview(sorted((OUT / "screenshots/1920x1080").glob("*.png")), video)
    print(f"  {video.relative_to(ROOT)} ({seconds:.1f} s)")
    (OUT / "icon").mkdir(parents=True)
    icon(OUT / "icon/headroom-icon-1024.png")
    print("  appstore/icon/headroom-icon-1024.png")


if __name__ == "__main__":
    main()
