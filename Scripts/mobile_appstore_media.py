#!/usr/bin/env python3
"""Turns the raw captures from Scripts/mobile_appstore_capture.py into the App Store assets for
Headroom on iPhone, iPhone Duo, iPad and Apple Watch, in appstore/mobile/:

- 1-normal/     The screenshots exactly as the simulator drew them, and the app previews as
                recorded, trimmed and encoded to the sizes App Store Connect accepts.
- 2-captioned/  The same screenshots and previews on one uniform brand color, with a headline
                and a device frame, exported at the same App Store sizes.
- creative/     The product page header and search results assets (images and looping videos),
                and the universal 16:9 image that can serve as both.

Static layers are laid out as HTML and drawn by headless Chrome; ffmpeg composes the videos.
Run with `make mobile-appstore`. Needs Google Chrome, ffmpeg and ImageMagick.
"""
import html
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "build/appstore-mobile/raw"
OUT = ROOT / "appstore/mobile"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ICON = ROOT / "Mobile/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

BG = "#2F6DF6"          # the captioned set's one background color
BG_HEX = "0x2F6DF6"
PAGE = "0x141619"       # the app's dark page color, behind the Duo's letterboxed previews
FONT = "-apple-system, 'SF Pro Display', system-ui, sans-serif"
STATE = {"plenty": "#6AA8FF", "onpace": "#ECEDF1", "tight": "#FFC248", "verytight": "#FF6982"}

# Where each set of screenshots goes: folder, raw device, App Store size, frame style.
SCREEN_TARGETS = [
    ("iphone-dynamic-island-medium-1206x2622", "iphone", (1206, 2622), "phone"),
    ("iphone-duo-outer-display-1398x2034", "duo", (1398, 2034), "duo"),
    ("ipad-13-inch-2752x2064", "ipad", (2752, 2064), "ipad"),
    ("watch-ultra-4-422x514", "watch-ultra-4", (422, 514), "watch"),
    ("watch-series-12-416x496", "watch-series-12", (416, 496), "watch"),
    ("watch-series-9-396x484", "watch-series-9", (396, 484), "watch"),
    ("watch-series-6-368x448", "watch-se-3", (368, 448), "watch"),
    ("watch-series-3-312x390", "watch-se-3", (312, 390), "watch"),
]
PREVIEW_TARGETS = [
    ("iphone-dynamic-island-medium-886x1920", "iphone", (886, 1920), "phone"),
    ("iphone-duo-886x1920", "duo", (886, 1920), "duo"),
    ("ipad-13-inch-1600x1200", "ipad", (1600, 1200), "ipad"),
]

# Headlines: (eyebrow, headline). Short phrases that add to the picture, not describe it.
CAPTIONS = {
    "01-now": ("Claude & Codex limits", "Will this week’s allowance last?"),
    "02-pace": ("Pace, not just a percentage", "Know when to use more, or ease off."),
    "03-session": ("5-hour sessions", "The limit you hit first, front and center."),
    "04-burn": ("Burn-o-meter", "See how fast you’re burning."),
    "05-history": ("History", "Every week and session, remembered."),
    "05-on-pace": ("Every account", "Work and personal, each on its own pace."),
    "06-activity": ("Activity", "See where the tokens go."),
    "07-activity-week": ("At API prices", "What your usage is worth."),
    "07-activity-month": ("At API prices", "What a month of usage is worth."),
    "08-lock-screen": ("Live Activity", "Your session, right on the Lock Screen."),
    "08-on-pace": ("Every account", "Work and personal, each on its own pace."),
    "08-light-account": ("Light or dark", "Easy on the eyes, day or night."),
    "09-macs": ("Every Mac", "Several Macs. One answer."),
    "10-light": ("Light or dark", "Easy on the eyes, day or night."),
}
# Where a device's screenshot needs its own headline.
DEVICE_CAPTIONS = {
    "ipad": {"10-light": ("Made for iPad", "Every account, on one screen.")},
}
# The ten watch screenshots, from the pages the watch flow captured (most urgent account first).
WATCH = [
    ("01-session", "codex-top", "Your 5-hour session, on your wrist."),
    ("02-warning", "claude-top", "A heads-up before it runs out."),
    ("03-paused", "paused-top", "Know exactly when you’re back."),
    ("04-accounts", "team-top", "Every account, one swipe away."),
    ("05-week", "codex-week", "Pace for the whole week."),
    ("06-plenty", "claude-week", "Room to spare? Spend it."),
    ("07-tight", "paused-week", "Ease off before it runs out."),
    ("08-on-pace", "team-week", "Right on pace."),
    ("09-sessions", "codex-foot", "Recent sessions at a glance."),
    ("10-updated", "claude-foot", "Always the latest from your Mac."),
]
PREVIEW_CAPTIONS = {
    "Pace": ("Your week, at a glance", "Will this week’s allowance last?"),
    "Session": ("5-hour sessions", "Never get cut off mid-task."),
    "Activity": ("Activity", "See where the tokens go."),
}

# Device frames, as fractions: text sizes of the canvas width, spacing of its height, the bezel
# and screen corners of the screen width.
STYLES = {
    "phone": dict(top=0.050, eyebrow=0.031, headline=0.076, lines=2, gap=0.030, bottom=0.028, bezel=0.030, radius=0.135, island=True, maxw=0.84),
    "duo": dict(top=0.050, eyebrow=0.028, headline=0.064, lines=2, gap=0.030, bottom=0.030, bezel=0.026, radius=0.075, island=False, maxw=0.88),
    "ipad": dict(top=0.055, eyebrow=0.015, headline=0.038, lines=1, gap=0.034, bottom=0.050, bezel=0.022, radius=0.036, island=False, maxw=0.90),
    "watch": dict(top=0.050, eyebrow=0, headline=0.066, lines=2, gap=0.030, bottom=0.050, bezel=0.075, radius=0.19, island=False, maxw=0.90),
}


def run(cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def opaque(src, out, size):
    """App Store Connect rejects alpha channels: write 8-bit RGB, and check the size."""
    run(["magick", str(src), "-auto-orient", "-strip", "-background", "black", "-alpha", "remove", "-alpha", "off",
         "-depth", "8", "-define", "png:color-type=2", str(out)])
    if png_size(out) != tuple(size):
        sys.exit(f"{out}: {png_size(out)} is not {size}")


def chrome(body, size, out, work, transparent=False):
    """Draws an HTML body at exactly `size` CSS pixels, one pixel each."""
    w, h = size
    page = work / (out.stem + ".html")
    page.write_text(f"<!doctype html><meta charset=utf-8><style>*{{box-sizing:border-box;margin:0;padding:0}}"
                    f"html,body{{width:{w}px;height:{h}px;overflow:hidden;background:transparent;"
                    f"-webkit-font-smoothing:antialiased}}</style><body>{body}</body>")
    args = [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
            f"--window-size={w},{h}", f"--screenshot={out}", "--allow-file-access-from-files"]
    if transparent:
        args.append("--default-background-color=00000000")
    # Chrome sometimes exits non-zero from its teardown watchdog after writing the file, so judge
    # by the file it wrote.
    for _ in range(3):
        out.unlink(missing_ok=True)
        subprocess.run(args + [page.as_uri()], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        if out.exists() and png_size(out) == (w, h):
            return
    sys.exit(f"Chrome couldn't draw {out.name} at {size}")


# MARK: Layout

def layout(style, canvas, screen):
    """Where the copy, the frame and the screen go on a captioned canvas."""
    s = STYLES[style]
    W, H = canvas
    ratio = screen[0] / screen[1]
    eb = round(W * s["eyebrow"])
    hl = round(W * s["headline"])
    text_top = round(H * s["top"])
    text_h = (eb * 1.25 + eb * 0.45 if eb else 0) + hl * 1.06 * s["lines"]
    dev_top = text_top + text_h + H * s["gap"]
    avail = H - dev_top - H * s["bottom"]
    sh = avail / (1 + 2 * s["bezel"] * ratio)
    sw = sh * ratio
    if sw * (1 + 2 * s["bezel"]) > W * s["maxw"]:
        sw = W * s["maxw"] / (1 + 2 * s["bezel"])
        sh = sw / ratio
    sw, sh = round(sw / 2) * 2, round(sh / 2) * 2
    b = round(sw * s["bezel"])
    fw, fh = sw + 2 * b, sh + 2 * b
    x = round((W - fw) / 2)
    y = round(dev_top + (avail - fh) / 2)
    return dict(eb=eb, hl=hl, text_top=text_top, frame=(x, y, fw, fh), screen=(x + b, y + b, sw, sh),
                bezel=b, radius=round(sw * s["radius"]), island=s["island"], width=W)


def copy_html(eyebrow, headline, g, color="#fff"):
    eb = (f'<div style="font:700 {g["eb"]}px/1.25 {FONT};letter-spacing:.13em;text-transform:uppercase;'
          f'color:rgba(255,255,255,.78);margin-bottom:{round(g["eb"] * .45)}px">{html.escape(eyebrow)}</div>') if g["eb"] else ""
    # An explicit width: Chrome's window is never narrower than about 500 px, wider than a watch canvas.
    return (f'<div style="position:absolute;left:0;width:{g["width"]}px;top:{g["text_top"]}px;text-align:center;'
            f'padding:0 {round(g["width"] * .06)}px">'
            f'{eb}<div style="font:800 {g["hl"]}px/1.06 {FONT};letter-spacing:-.02em;color:{color};text-wrap:balance">'
            f'{html.escape(headline)}</div></div>')


def frame_html(g, src=None, hole_color=None):
    """A device: the screenshot (or a transparent hole of the screen's shape for a video), its
    bezel, and the Dynamic Island. The bezel reaches 2 px over the screen to hide the seam."""
    x, y, fw, fh = g["frame"]
    sx, sy, sw, sh = g["screen"]
    b, r = g["bezel"], g["radius"]
    ring = max(1, round(b * .1))
    shadow = f"0 0 0 {ring}px rgba(255,255,255,.28), 0 {round(fh * .03)}px {round(fh * .06)}px rgba(6,16,64,.42)"
    parts = []
    if hole_color:
        parts.append(f'<div style="position:absolute;left:{sx}px;top:{sy}px;width:{sw}px;height:{sh}px;'
                     f'border-radius:{r}px;box-shadow:0 0 0 {max(fw, fh) * 4}px {hole_color}"></div>')
    else:
        parts.append(f'<img src="{src}" style="position:absolute;left:{sx}px;top:{sy}px;width:{sw}px;height:{sh}px;'
                     f'border-radius:{r}px;display:block">')
    parts.append(f'<div style="position:absolute;left:{x}px;top:{y}px;width:{fw}px;height:{fh}px;border-radius:{r + b}px;'
                 f'border:{b + 2}px solid #0B0B0E;box-shadow:{shadow}"></div>')
    if g["island"]:
        iw, ih = round(sw * .31), round(sh * .042)
        parts.append(f'<div style="position:absolute;left:{round(sx + (sw - iw) / 2)}px;top:{round(sy + sh * .0125)}px;'
                     f'width:{iw}px;height:{ih}px;border-radius:{ih}px;background:#000"></div>')
    return "".join(parts)


# MARK: Screenshots

def raw_screens(device):
    folder = RAW / device / "screens"
    shots = sorted(folder.glob("*.png")) if folder.exists() else []
    if not shots:
        print(f"  (no raw screenshots for {device}; run Scripts/mobile_appstore_capture.py)")
    return shots


def upright(src, size, out):
    """A raw shot at the App Store size. Landscape iPad shots arrive in the portrait framebuffer
    with an EXIF orientation, which -auto-orient applies; the Series 3 size is the SE 3 shot
    scaled down onto black (the watch app's background)."""
    tmp = out.with_suffix(".tmp.png")
    run(["magick", str(src), "-auto-orient", "-strip", str(tmp)])
    if png_size(tmp) != tuple(size):
        run(["magick", str(tmp), "-filter", "Lanczos", "-resize", f"{size[0]}x{size[1]}", "-background", "black",
             "-gravity", "center", "-extent", f"{size[0]}x{size[1]}", str(tmp)])
    opaque(tmp, out, size)
    tmp.unlink()


def screenshots(work):
    for folder, device, size, style in SCREEN_TARGETS:
        shots = raw_screens(device)
        if not shots:
            continue
        normal, captioned = OUT / "1-normal" / folder, OUT / "2-captioned" / folder
        for d in (normal, captioned):
            shutil.rmtree(d, ignore_errors=True)
            d.mkdir(parents=True)
        picks = []
        if style == "watch":
            by_name = {p.stem: p for p in shots}
            picks = [(name, by_name[src], caption) for name, src, caption in WATCH if src in by_name]
        else:
            captions = {**CAPTIONS, **DEVICE_CAPTIONS.get(device, {})}
            picks = [(p.stem, p, captions.get(p.stem, ("", ""))) for p in shots]
        for name, src, caption in picks:
            out = normal / f"{name}.png"
            upright(src, size, out)
            g = layout(style, size, size)
            eyebrow, headline = ("", caption) if style == "watch" else caption
            body = (f'<div style="position:absolute;inset:0;background:{BG}"></div>'
                    f'{copy_html(eyebrow, headline, g)}{frame_html(g, out.as_uri())}')
            drawn = work / f"{folder}-{name}.png"
            chrome(body, size, drawn, work)
            opaque(drawn, captioned / f"{name}.png", size)
        print(f"  {folder}: {len(picks)} + {len(picks)}")


# MARK: Previews

def probe(path):
    """Size, duration, frame rate and audio of a video, as ffprobe reports them."""
    out = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))
    video = next(s for s in out["streams"] if s["codec_type"] == "video")
    audio = next((s for s in out["streams"] if s["codec_type"] == "audio"), {})
    num, den = (int(x) for x in video["avg_frame_rate"].split("/"))
    return dict(size=(video["width"], video["height"]), seconds=float(out["format"]["duration"]), fps=num / den,
                profile=video.get("profile"), level=video.get("level"), channels=audio.get("channels"),
                audio=audio.get("codec_name"), mb=int(out["format"]["size"]) / 1e6)


def encode(inputs, graph, out, seconds, level="4.0", rate="11M"):
    """H.264 High at 30 fps with the silent stereo AAC track app previews need."""
    run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-f", "lavfi", "-t", f"{seconds:.3f}",
         "-i", "anullsrc=channel_layout=stereo:sample_rate=48000", "-filter_complex", graph,
         "-map", "[out]", "-map", f"{inputs.count('-i')}:a", "-t", f"{seconds:.3f}",
         "-c:v", "libx264", "-profile:v", "high", "-level", level, "-preset", "slow", "-pix_fmt", "yuv420p",
         "-b:v", rate, "-maxrate", "12M" if level == "4.0" else "40M", "-bufsize", "24M" if level == "4.0" else "80M", "-r", "30",
         "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", str(out)])


def preview_clip(device, name):
    folder = RAW / device / "previews"
    info = folder / f"{name}.json"
    if not info.exists():
        return None
    m = json.loads(info.read_text())
    start = m["start"] - m["recordingStarted"]
    end = m["end"] - m["recordingStarted"]
    length = min(end - start, 29.5)
    if length < 15:
        print(f"  ({device} {name} is only {length:.1f} s; App Store previews need 15 s)")
    return folder / f"{name}.mov", max(start, 0), length, m.get("landscape", False)


def previews(work):
    for folder, device, size, style in PREVIEW_TARGETS:
        normal, captioned = OUT / "1-normal/previews" / folder, OUT / "2-captioned/previews" / folder
        made = 0
        for i, name in enumerate(["Pace", "Session", "Activity"], 1):
            clip = preview_clip(device, name)
            if not clip:
                continue
            for d in (normal, captioned):
                d.mkdir(parents=True, exist_ok=True)
            src, start, length, landscape = clip
            W, H = size
            turn = "transpose=2," if landscape else ""
            fades = f"fade=t=in:st=0:d=0.3,fade=t=out:st={length - 0.35:.3f}:d=0.35"
            # 1. As recorded: the iPhone fills the frame (3 px trimmed off each end), the iPad scales
            #    exactly, and the Duo's wider outer display sits on the app's page color.
            if style == "duo":
                fit = f"scale={W}:-2:flags=lanczos,pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color={PAGE}"
            else:
                fit = f"scale={W}:{H}:force_original_aspect_ratio=increase:flags=lanczos,crop={W}:{H}"
            graph = f"[0:v]fps=30,{turn}{fit},setsar=1,{fades},format=yuv420p[out]"
            out = normal / f"{i}-{name.lower()}.mp4"
            encode(["-ss", f"{start:.3f}", "-t", f"{length:.3f}", "-i", str(src)], graph, out, length)
            # 2. Captioned: the recording inside a device frame on the brand color, under a headline.
            raw_w, raw_h = DEVICE_SIZES[device]
            g = layout(style, size, (raw_w, raw_h))
            eyebrow, headline = PREVIEW_CAPTIONS[name]
            overlay = work / f"{folder}-{name}-frame.png"
            chrome(f'{frame_html(g, hole_color=BG)}{copy_html(eyebrow, headline, g)}', size, overlay, work, transparent=True)
            sx, sy, sw, sh = g["screen"]
            graph = (f"color=c={BG_HEX}:s={W}x{H}:r=30[bg];"
                     f"[0:v]fps=30,{turn}scale={sw}:{sh}:flags=lanczos,setsar=1[v];"
                     f"[bg][v]overlay={sx}:{sy}:shortest=1[b];[b][1:v]overlay=0:0:shortest=1,{fades},format=yuv420p[out]")
            encode(["-ss", f"{start:.3f}", "-t", f"{length:.3f}", "-i", str(src), "-loop", "1", "-framerate", "30", "-i", str(overlay)],
                   graph, captioned / f"{i}-{name.lower()}.mp4", length)
            made += 1
        if made:
            print(f"  previews/{folder}: {made} + {made}")


DEVICE_SIZES = {"iphone": (1206, 2622), "duo": (1398, 2034), "ipad": (2752, 2064)}


# MARK: Creative assets (product page header, search results, universal)

GLOW = (f"radial-gradient(48% 70% at 88% 12%, rgba(74,142,255,.42), transparent 70%),"
        f"radial-gradient(42% 64% at 8% 92%, rgba(255,194,72,.20), transparent 70%),"
        f"radial-gradient(36% 56% at 60% 108%, rgba(255,105,130,.16), transparent 70%),"
        f"linear-gradient(160deg, #10162B, #090B12 58%, #0B1220)")


def meter_html(x, y, w, h, states=("plenty", "plenty", "plenty", "dim", "dim")):
    gap = round(w * .022)
    cell = (w - gap * 4) / 5
    cells = []
    for i, s in enumerate(states):
        color = "rgba(255,255,255,.12)" if s == "dim" else STATE[s]
        glow = "" if s == "dim" else f";box-shadow:0 0 {round(h * .9)}px {color}"
        cells.append(f'<div style="position:absolute;left:{round(i * (cell + gap))}px;top:0;width:{round(cell)}px;height:{h}px;'
                     f'border-radius:{round(h * .32)}px;background:{color}{glow}"></div>')
    return f'<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px">{"".join(cells)}</div>'


def device_at(src, screen_px, x, y, height, style):
    """A framed device of the given outer height with its top-left at (x, y)."""
    s = STYLES[style]
    ratio = screen_px[0] / screen_px[1]
    sh = height / (1 + 2 * s["bezel"] * ratio)
    sw = sh * ratio
    sw, sh = round(sw / 2) * 2, round(sh / 2) * 2
    b = round(sw * s["bezel"])
    g = dict(frame=(x, y, sw + 2 * b, sh + 2 * b), screen=(x + b, y + b, sw, sh), bezel=b,
             radius=round(sw * s["radius"]), island=s["island"])
    return g, frame_html(g, src)


def bezels_html(gs_):
    """Only the bezels and islands, on a transparent page: laid over the videos to hide their edges."""
    out = []
    for g in gs_:
        x, y, fw, fh = g["frame"]
        b, r = g["bezel"], g["radius"]
        out.append(f'<div style="position:absolute;left:{x}px;top:{y}px;width:{fw}px;height:{fh}px;border-radius:{r + b}px;'
                   f'border:{b + 2}px solid #0B0B0E"></div>')
        if g["island"]:
            sx, sy, sw, sh = g["screen"]
            iw, ih = round(sw * .31), round(sh * .042)
            out.append(f'<div style="position:absolute;left:{round(sx + (sw - iw) / 2)}px;top:{round(sy + sh * .0125)}px;'
                       f'width:{iw}px;height:{ih}px;border-radius:{ih}px;background:#000"></div>')
    return "".join(out)


def headline_block(x, y, w, size, align="center", sub=None, sub_size=None, eyebrow=None):
    parts = [f'<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;text-align:{align}">']
    if eyebrow:
        parts.append(f'<div style="font:700 {round(size * .26)}px/1.2 {FONT};letter-spacing:.14em;text-transform:uppercase;'
                     f'color:rgba(244,244,246,.62);margin-bottom:{round(size * .22)}px">{html.escape(eyebrow)}</div>')
    parts.append(f'<div style="font:800 {size}px/1.04 {FONT};letter-spacing:-.032em;color:#F5F5F7;text-wrap:balance">'
                 f'Will this week’s allowance last?</div>')
    if sub:
        parts.append(f'<div style="margin-top:{round(size * .3)}px;font:500 {sub_size}px/1.35 {FONT};color:rgba(244,244,246,.66);'
                     f'text-wrap:balance">{html.escape(sub)}</div>')
    parts.append("</div>")
    return "".join(parts)


def frame_size(screen_px, height, style):
    """The outer width of a framed device of the given outer height."""
    s = STYLES[style]
    ratio = screen_px[0] / screen_px[1]
    sh = height / (1 + 2 * s["bezel"] * ratio)
    sw = round(sh * ratio / 2) * 2
    return sw + 2 * round(sw * s["bezel"])


def creative(work):
    out = OUT / "creative"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    phone = OUT / "1-normal/iphone-dynamic-island-medium-1206x2622/01-now.png"
    pad = OUT / "1-normal/ipad-13-inch-2752x2064/01-now.png"
    watch = OUT / "1-normal/watch-ultra-4-422x514/01-session.png"
    if not (phone.exists() and pad.exists()):
        print("  (creative assets need the iPhone and iPad screenshots)")
        return
    icon = ICON.as_uri()
    background = f'<div style="position:absolute;inset:0;background:{GLOW}"></div>'
    phone_px, pad_px, watch_px = (1206, 2622), (2752, 2064), (422, 514)

    def icon_html(x, y, size):
        return (f'<img src="{icon}" style="position:absolute;left:{x}px;top:{y}px;width:{size}px;height:{size}px;'
                f'border-radius:{round(size * .225)}px;box-shadow:0 {round(size * .12)}px {round(size * .27)}px rgba(0,0,0,.45)">')

    def centered(W, safe_x, safe_w, top, icon_size, size, meter_w):
        """The icon, the two-line headline and the meter, centered in the safe area."""
        head_top = top + icon_size + round(size * .3)
        meter_top = head_top + round(size * 1.04 * 2) + round(size * .42)
        return (icon_html((W - icon_size) // 2, top, icon_size) + headline_block(safe_x, head_top, safe_w, size)
                + meter_html((W - meter_w) // 2, meter_top, meter_w, round(size * .27)))

    # Product page header, 21:9. The icon, headline and meter stay inside the art safe area (a
    # centered 1646 x 661 box in Apple's template); the devices either side may crop away.
    W, H = 3840, 1646
    gp, header_phone = device_at(phone.as_uri(), phone_px, 290, 150, 1346, "phone")
    pad_h = 820
    gi, header_pad = device_at(pad.as_uri(), pad_px, W - frame_size(pad_px, pad_h, "ipad") - 120, (H - pad_h) // 2, pad_h, "ipad")
    header_copy = centered(W, 1097, 1646, 503, 120, 138, 600)
    chrome(background + header_phone + header_pad + header_copy, (W, H), work / "header.png", work)
    opaque(work / "header.png", out / "header-3840x1646.png", (W, H))

    # Search results, 3:2 at the largest size. The copy sits inside the art safe area (a centered
    # 2168 x 1030 box); the phone and the watch run past it top and bottom.
    def search(k, phone_src, watch_src):
        x0, y0 = round(836 * k), round(765 * k)
        copy = headline_block(x0 + round(70 * k), y0 + round(150 * k), round(1240 * k), round(124 * k), align="left",
                              eyebrow="Headroom for iPhone, iPad & Apple Watch",
                              sub="See what’s left of your Claude and Codex plans against the time left.", sub_size=round(52 * k))
        ph = round(1560 * k)
        g, phone_html = device_at(phone_src, phone_px, round(2290 * k), round(1280 * k) - ph // 2, ph, "phone")
        watch_html = device_at(watch_src, watch_px, round(2860 * k), round(1480 * k), round(560 * k), "watch")[1] if watch.exists() else ""
        glow = (f'<div style="position:absolute;left:{round(1900 * k)}px;top:{round(380 * k)}px;width:{round(1700 * k)}px;'
                f'height:{round(1800 * k)}px;background:radial-gradient(closest-side, rgba(74,142,255,.30), transparent)"></div>')
        # The watch sits in front of the phone, so the video version draws it above the recording.
        return g, background + glow + copy + phone_html, watch_html

    W, H = 3840, 2560
    gs, search_html, search_watch = search(1, phone.as_uri(), watch.as_uri())
    chrome(search_html + search_watch, (W, H), work / "search.png", work)
    opaque(work / "search.png", out / "search-results-3840x2560.png", (W, H))

    # Universal 16:9, for both placements. Safe area: 1402 x 962 at (1921, 660).
    W, H = 5244, 2950
    pad_h = 1240
    universal = (device_at(phone.as_uri(), phone_px, 560, 355, 2240, "phone")[1]
                 + device_at(pad.as_uri(), pad_px, W - frame_size(pad_px, pad_h, "ipad") - 170, 855, pad_h, "ipad")[1]
                 + centered(W, 1921, 1402, 676, 130, 132, 560))
    chrome(background + universal, (W, H), work / "universal.png", work)
    opaque(work / "universal.png", out / "universal-5244x2950.png", (W, H))
    print("  creative: header, search results and universal images")

    # Videos: the same layouts with the screens playing recordings that open on a still hold.
    clips = {d: preview_clip(d, "Activity") for d in ("iphone", "ipad")}
    if not all(clips.values()):
        print("  (creative videos need the iPhone and iPad Activity recordings)")
        return
    W, H = 3840, 1646
    length = min(clips["iphone"][2], clips["ipad"][2], 29.0)
    chrome(background + header_phone + header_pad + header_copy, (W, H), work / "header-base.png", work)
    chrome(bezels_html([gp, gi]), (W, H), work / "header-top.png", work, transparent=True)
    loop_video(out / "header-3840x1646.mp4", (W, H), work / "header-base.png", work / "header-top.png",
               [(clips["iphone"], gp), (clips["ipad"], gi)], length, work, level="5.1", rate="36M")

    # Search results video at 1920 x 1280, the smallest accepted 3:2 size, to keep the file light.
    W, H = 1920, 1280
    gs2, search_html2, search_watch2 = search(0.5, phone.as_uri(), watch.as_uri())
    pace = preview_clip("iphone", "Pace") or clips["iphone"]
    chrome(search_html2, (W, H), work / "search-base.png", work)
    chrome(bezels_html([gs2]) + search_watch2, (W, H), work / "search-top.png", work, transparent=True)
    loop_video(out / "search-results-1920x1280.mp4", (W, H), work / "search-base.png", work / "search-top.png",
               [(pace, gs2)], min(pace[2], 29.0), work, level="5.1", rate="16M")
    print("  creative: header and search results videos")


def loop_video(out, size, base, top, sources, length, work, level, rate):
    """Recordings rounded to their screens between a base layer and the bezels, cross-fading back
    into the opening hold over the last 0.8 s so the video loops without a jump."""
    W, H = size
    inputs = ["-loop", "1", "-framerate", "30", "-t", f"{length:.3f}", "-i", str(base)]
    chains, last = [], "0:v"
    for i, ((src, start, _, landscape), g) in enumerate(sources):
        sx, sy, sw, sh = g["screen"]
        mask = work / f"mask-{sw}x{sh}-{g['radius']}.png"
        run(["magick", "-size", f"{sw}x{sh}", "xc:black", "-fill", "white", "-draw",
             f"roundrectangle 0,0 {sw - 1},{sh - 1} {g['radius']},{g['radius']}", str(mask)])
        v, m = 1 + 2 * i, 2 + 2 * i
        inputs += ["-ss", f"{start:.3f}", "-t", f"{length:.3f}", "-i", str(src), "-loop", "1", "-framerate", "30", "-i", str(mask)]
        turn = "transpose=2," if landscape else ""
        chains.append(f"[{v}:v]fps=30,{turn}scale={sw}:{sh}:flags=lanczos,setsar=1,format=yuva420p[v{i}]")
        chains.append(f"[{m}:v]format=gray,scale={sw}:{sh}[m{i}]")
        chains.append(f"[v{i}][m{i}]alphamerge[r{i}]")
        chains.append(f"[{last}][r{i}]overlay={sx}:{sy}:shortest=1[b{i}]")
        last = f"b{i}"
    n = 1 + 2 * len(sources)
    inputs += ["-loop", "1", "-framerate", "30", "-i", str(top)]
    chains.append(f"[{last}][{n}:v]overlay=0:0:shortest=1,format=yuv420p,split[main][head]")
    chains.append("[head]trim=0:0.8,setpts=PTS-STARTPTS[h]")
    chains.append(f"[main][h]xfade=transition=fade:duration=0.8:offset={length - 0.8:.3f}[out]")
    encode(inputs, ";".join(chains), out, length, level=level, rate=rate)


# MARK: Main

def main():
    for tool in ("ffmpeg", "ffprobe", "magick"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is needed (brew install ffmpeg imagemagick).")
    if not Path(CHROME).exists():
        sys.exit("Google Chrome is needed to draw the captioned assets.")
    if not RAW.exists():
        sys.exit("No raw captures yet: run Scripts/mobile_appstore_capture.py first.")
    for sub in ("1-normal", "2-captioned", "creative"):
        shutil.rmtree(OUT / sub, ignore_errors=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        print("Writing appstore/mobile/")
        screenshots(work)
        previews(work)
        creative(work)
    verify()


def verify():
    """Checks every file against what App Store Connect accepts, and prints what was made."""
    problems = []
    for folder, _, size, _ in SCREEN_TARGETS:
        for part in ("1-normal", "2-captioned"):
            files = sorted((OUT / part / folder).glob("*.png"))
            bad = [f.name for f in files if png_size(f) != size]
            if len(files) != 10 or bad:
                problems.append(f"{part}/{folder}: {len(files)} screenshots, wrong size: {bad}")
    for folder, _, size, _ in PREVIEW_TARGETS:
        for part in ("1-normal", "2-captioned"):
            for f in sorted((OUT / part / "previews" / folder).glob("*.mp4")):
                m = probe(f)
                ok = (m["size"] == size and 15 <= m["seconds"] <= 30 and abs(m["fps"] - 30) < 0.01
                      and m["channels"] == 2 and m["audio"] == "aac" and m["level"] <= 40)
                if not ok:
                    problems.append(f"{part}/previews/{folder}/{f.name}: {m}")
    for f in sorted((OUT / "creative").glob("*.mp4")):
        m = probe(f)
        if not 5 <= m["seconds"] <= 30:
            problems.append(f"creative/{f.name}: {m}")
    print("All files match the App Store specifications." if not problems else "Problems:\n  " + "\n  ".join(problems))


if __name__ == "__main__":
    main()
