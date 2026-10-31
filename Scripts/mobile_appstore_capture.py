#!/usr/bin/env python3
"""Captures the raw App Store screenshots and app preview recordings for Headroom on iPhone,
iPhone Duo, iPad and Apple Watch, into build/appstore-mobile/raw/.

1. Generates Mobile/HeadroomScreenshots.xcodeproj (Mobile/screenshots.yml: the app plus UI test
   bundles) and builds it unsigned for the simulators, on sample data (HEADROOM_CLOUDKIT=NO).
2. Makes (or reuses) one "Headroom Capture" simulator per App Store size, in US English with
   12-hour time, and boots it in a fixed-offset zone where the clock reads 9:41. The zone covers
   the whole simulator, so the Lock Screen and the Live Activity agree with the app.
3. Runs the screenshot flows (Mobile/UITests), which write PNGs straight to the raw folder.
4. Records each app preview flow with `simctl io recordVideo`, rebooting first so every preview
   starts at 9:41, and keeps the start and end marks the flow logs, for trimming.

Then `Scripts/mobile_appstore_media.py` turns the raw captures into appstore/mobile/. Run both
with `make mobile-appstore`. Needs Xcode with the iOS, iPhone Duo and watchOS simulator runtimes,
and XcodeGen.
"""
import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build/appstore-mobile"
RAW = BUILD / "raw"
PROJECT = ROOT / "Mobile/HeadroomScreenshots.xcodeproj"
DD = {"ios": BUILD / "dd-ios", "watch": BUILD / "dd-watch"}
SCHEME = {"ios": "HeadroomScreenshots", "watch": "HeadroomWatchScreenshots"}
UNSIGNED = ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "HEADROOM_CLOUDKIT=NO"]

# One simulator per App Store size. `size` is the screenshot in pixels, upright.
DEVICES = {
    "iphone": dict(type="iPhone-18-Pro", kind="ios", size=(1206, 2622)),
    "duo": dict(type="iPhone-Duo", kind="ios", size=(1398, 2034), display=(1398, 2034)),
    "ipad": dict(type="iPad-Pro-13-inch-M5-12GB", kind="ios", size=(2752, 2064), landscape=True),
    "watch-ultra-4": dict(type="Apple-Watch-Ultra-4-49mm", kind="watch", size=(422, 514)),
    "watch-series-12": dict(type="Apple-Watch-Series-12-46mm", kind="watch", size=(416, 496)),
    "watch-series-9": dict(type="Apple-Watch-Series-9-45mm", kind="watch", size=(396, 484)),
    # Series 6 can't run watchOS 27; SE 3 (44 mm) has the same 368 x 448 screen.
    "watch-se-3": dict(type="Apple-Watch-SE-3-44mm", kind="watch", size=(368, 448)),
}
PREVIEWS = ["Pace", "Session", "Activity"]


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def run(cmd, check=True, quiet=True, **kw):
    out = subprocess.DEVNULL if quiet else None
    return subprocess.run(cmd, check=check, stdout=kw.pop("stdout", out), stderr=kw.pop("stderr", out), **kw)


def simctl_json(*what):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *what]))


# MARK: Simulators

def runtime_for(type_id):
    """The newest available runtime that supports this device type."""
    best = None
    for r in simctl_json("runtimes")["runtimes"]:
        if not r.get("isAvailable"):
            continue
        if any(d["identifier"] == type_id for d in r.get("supportedDeviceTypes", [])):
            v = tuple(int(x) for x in r["version"].split("."))
            if best is None or v > best[0]:
                best = (v, r["identifier"], r["name"])
    if not best:
        sys.exit(f"No simulator runtime supports {type_id}. Install it in Xcode → Settings → Components.")
    return best[1], best[2]


def device_for(key):
    spec = DEVICES[key]
    type_id = "com.apple.CoreSimulator.SimDeviceType." + spec["type"]
    runtime, runtime_name = runtime_for(type_id)
    name = f"Headroom Capture {key}"
    for rid, devs in simctl_json("devices")["devices"].items():
        for d in devs:
            if d["name"] == name and rid == runtime and d.get("isAvailable"):
                return d["udid"], runtime_name, False
    udid = subprocess.check_output(["xcrun", "simctl", "create", name, type_id, runtime], text=True).strip()
    return udid, runtime_name, True


def booted(udid):
    for devs in simctl_json("devices")["devices"].values():
        for d in devs:
            if d["udid"] == udid:
                return d["state"] == "Booted"
    return False


def boot(udid, tz=None):
    env = dict(os.environ)
    if tz:
        env["SIMCTL_CHILD_TZ"] = tz
    run(["xcrun", "simctl", "boot", udid], check=False, env=env)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=False)


def shutdown(udid):
    if booted(udid):
        run(["xcrun", "simctl", "shutdown", udid], check=False)


def configure(udid):
    """US English and 12-hour time, so the status bar reads 9:41 and times read 1:53 PM."""
    boot(udid)
    for args in (["AppleLocale", "-string", "en_US"], ["AKLastLocale", "-string", "en_US"],
                 ["AppleICUForce24HourTime", "-bool", "NO"], ["AppleLanguages", "-array", "en"]):
        run(["xcrun", "simctl", "spawn", udid, "defaults", "write", "-g", *args], check=False)
    shutdown(udid)


def zone_reading(hour, minute, lead):
    """A fixed-offset zone ("GMT+1014") in which it will be hour:minute `lead` seconds from now."""
    then = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=lead)
    offset = (hour * 60 + minute) - (then.hour * 60 + then.minute)
    if offset > 14 * 60:
        offset -= 24 * 60
    if offset < -12 * 60:
        offset += 24 * 60
    return "GMT%s%02d%02d" % ("-" if offset < 0 else "+", abs(offset) // 60, abs(offset) % 60)


def fresh_boot(key, udid, lead):
    """Reboots in a zone where it's 9:41 `lead` seconds from now; pins full signal and battery."""
    ios = DEVICES[key]["kind"] == "ios"
    shutdown(udid)
    tz = zone_reading(9, 41, lead + (20 if ios else 0))
    if ios:
        # A moment after waking, the Lock Screen clock switches to the zone the previous boot left
        # behind, so boot once in the new zone first.
        boot(udid, tz)
        time.sleep(3)
        shutdown(udid)
    boot(udid, tz)
    if ios:
        run(["xcrun", "simctl", "ui", udid, "appearance", "dark"], check=False)
        run(["xcrun", "simctl", "status_bar", udid, "override", "--dataNetwork", "wifi", "--wifiMode", "active",
             "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging",
             "--batteryLevel", "100", "--operatorName", ""], check=False)
    time.sleep(4)
    return tz


def display_id(udid, size):
    """The framebuffer of the given pixel size (the Duo's outer display), for recordVideo."""
    out = subprocess.check_output(["xcrun", "simctl", "io", udid, "enumerate"], text=True)
    for block in out.split("Port:"):
        m = re.search(r"UUID: (\S+)", block)
        if m and f"Default width: {size[0]}" in block and f"Default height: {size[1]}" in block:
            return m.group(1)
    return None


# MARK: Tests

def build(kinds):
    log("Generating Mobile/HeadroomScreenshots.xcodeproj")
    run(["xcodegen", "generate", "--spec", "screenshots.yml"], cwd=ROOT / "Mobile")
    for kind in kinds:
        platform = "iOS Simulator" if kind == "ios" else "watchOS Simulator"
        log(f"Building {SCHEME[kind]} for the {platform}")
        logfile = BUILD / f"build-{kind}.log"
        with open(logfile, "w") as f:
            r = subprocess.run(["xcodebuild", "build-for-testing", "-project", str(PROJECT), "-scheme", SCHEME[kind],
                                "-destination", f"generic/platform={platform}", "-derivedDataPath", str(DD[kind]), *UNSIGNED],
                               stdout=f, stderr=subprocess.STDOUT)
        if r.returncode:
            sys.exit(f"Build failed; see {logfile}")


def xctest(key, udid, only, env, logname):
    kind = DEVICES[key]["kind"]
    full_env = dict(os.environ)
    full_env.update({f"TEST_RUNNER_{k}": v for k, v in env.items()})
    logfile = RAW / key / f"{logname}.log"
    with open(logfile, "w") as f:
        r = subprocess.run(["xcodebuild", "test-without-building", "-project", str(PROJECT), "-scheme", SCHEME[kind],
                            "-destination", f"platform={'iOS' if kind == 'ios' else 'watchOS'} Simulator,id={udid}",
                            "-derivedDataPath", str(DD[kind]), f"-only-testing:{only}"],
                           stdout=f, stderr=subprocess.STDOUT, env=full_env)
    if r.returncode:
        raise RuntimeError(f"{key}: {only} failed; see {logfile}")


def screenshots(key, udid):
    kind = DEVICES[key]["kind"]
    out = RAW / key / "screens"
    out.mkdir(parents=True, exist_ok=True)
    for f in out.glob("*.png"):
        f.unlink()
    tz = fresh_boot(key, udid, lead=40 if kind == "ios" else 45)
    only = ("HeadroomScreenshotUITests/ScreenshotTests" if kind == "ios"
            else "HeadroomWatchScreenshotUITests/WatchCaptureTests/testScreenshots")
    log(f"{key}: screenshots ({tz})")
    xctest(key, udid, only, {"HR_SHOT_DIR": str(out), "HR_TZ": tz}, "screenshots")
    log(f"{key}: {len(list(out.glob('*.png')))} screenshots")


class Recorder:
    """`simctl io recordVideo` in the background, started and stopped around one flow."""

    def __init__(self, udid, path, display=None):
        cmd = ["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force"]
        if display:
            cmd.append(f"--display={display}")
        self.proc = subprocess.Popen(cmd + [str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.started = None
        self.ready = threading.Event()
        threading.Thread(target=self._watch, daemon=True).start()
        if not self.ready.wait(30):
            self.proc.kill()
            raise RuntimeError("recordVideo didn't start")

    def _watch(self):
        for line in self.proc.stdout:
            if "Recording started" in line and not self.ready.is_set():
                self.started = time.time()
                self.ready.set()

    def stop(self):
        self.proc.send_signal(signal.SIGINT)
        try:
            self.proc.wait(60)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def previews(key, udid):
    spec = DEVICES[key]
    out = RAW / key / "previews"
    out.mkdir(parents=True, exist_ok=True)
    display = display_id(udid, spec["display"]) if spec.get("display") else None
    for name in PREVIEWS:
        marks = out / f"{name}.marks"
        marks.unlink(missing_ok=True)
        tz = fresh_boot(key, udid, lead=55)
        if display:
            display = display_id(udid, spec["display"]) or display
        log(f"{key}: preview {name} ({tz})")
        rec = Recorder(udid, out / f"{name}.mov", display)
        try:
            xctest(key, udid, f"HeadroomScreenshotUITests/PreviewTests/testPreview{name}",
                   {"HR_MARKS": str(marks), "HR_TZ": tz, "HR_SHOT_DIR": str(out)}, f"preview-{name}")
        finally:
            time.sleep(1)
            rec.stop()
        m = dict(line.split() for line in marks.read_text().splitlines() if line.strip())
        info = {"recordingStarted": rec.started, "start": float(m["start"]), "end": float(m["end"]),
                "landscape": bool(spec.get("landscape"))}
        (out / f"{name}.json").write_text(json.dumps(info, indent=2))
        log(f"{key}: preview {name}: {info['end'] - info['start']:.1f} s")


def capture(key, do_shots, do_previews):
    udid, runtime, created = device_for(key)
    (RAW / key).mkdir(parents=True, exist_ok=True)
    log(f"{key}: {udid} on {runtime}{' (new)' if created else ''}")
    configure(udid)
    try:
        if do_shots:
            screenshots(key, udid)
        if do_previews and DEVICES[key]["kind"] == "ios":
            previews(key, udid)
    finally:
        shutdown(udid)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--only", help="comma-separated devices: " + ", ".join(DEVICES))
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--no-screenshots", action="store_true")
    parser.add_argument("--no-previews", action="store_true")
    parser.add_argument("--previews", help="comma-separated previews to record: " + ", ".join(PREVIEWS))
    args = parser.parse_args()
    keys = args.only.split(",") if args.only else list(DEVICES)
    if args.previews:
        PREVIEWS[:] = [p for p in PREVIEWS if p in args.previews.split(",")]
    for k in keys:
        if k not in DEVICES:
            sys.exit(f"Unknown device {k}")
    BUILD.mkdir(parents=True, exist_ok=True)
    kinds = sorted({DEVICES[k]["kind"] for k in keys})
    if not args.skip_build:
        build(kinds)
    failures = []
    # The phones and the iPad run side by side, then the watches.
    for group in ([k for k in keys if DEVICES[k]["kind"] == "ios"], [k for k in keys if DEVICES[k]["kind"] == "watch"]):
        if not group:
            continue
        with ThreadPoolExecutor(len(group)) as pool:
            futures = {k: pool.submit(capture, k, not args.no_screenshots, not args.no_previews) for k in group}
            for k, f in futures.items():
                try:
                    f.result()
                except Exception as e:  # keep the other devices' captures
                    failures.append(f"{k}: {e}")
    if failures:
        sys.exit("Some captures failed:\n  " + "\n  ".join(failures))
    log(f"Raw captures are in {RAW.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
