#!/usr/bin/env python3
"""Adds a release to appcast.xml, the feed Headroom's in-app updater (Sparkle) reads.

    python3 -I Scripts/appcast.py <appcast.xml> <version> <build> <zip url> <signature attributes>

<signature attributes> is what Sparkle's sign_update prints for the zip:
    sparkle:edSignature="..." length="..."
A version with a suffix (1.2.3-beta.4) goes in the "beta" channel, which only installs that opted
into betas see. The newest items come first; an item for the same build is replaced, and the feed
keeps the last MAX_ITEMS releases.
"""

import re
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MAX_ITEMS = 12
MIN_SYSTEM = "15.0"
HOMEPAGE = "https://github.com/ScaleXY/headroom"

ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def sp(tag):
    return f"{{{SPARKLE}}}{tag}"


def main(path, version, build, url, signature):
    attrs = dict(re.findall(r'([\w:]+)="([^"]*)"', signature))
    if "sparkle:edSignature" not in attrs or "length" not in attrs:
        sys.exit(f"error: expected sign_update output, got: {signature!r}")
    if not build.isdigit():
        sys.exit(f"error: build must be a number, got {build!r}")

    try:
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
    except FileNotFoundError:
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Headroom"
        ET.SubElement(channel, "link").text = HOMEPAGE
        ET.SubElement(channel, "description").text = "Headroom releases"
        tree = ET.ElementTree(rss)

    for old in channel.findall("item"):
        if old.findtext(sp("version")) == build:
            channel.remove(old)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Headroom {version}"
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(item, sp("version")).text = build
    ET.SubElement(item, sp("shortVersionString")).text = version
    ET.SubElement(item, sp("minimumSystemVersion")).text = MIN_SYSTEM
    if "-" in version:
        ET.SubElement(item, sp("channel")).text = "beta"
    ET.SubElement(item, sp("fullReleaseNotesLink")).text = f"{HOMEPAGE}/releases/tag/v{version}"
    ET.SubElement(item, "enclosure", {
        "url": url,
        "type": "application/octet-stream",
        sp("edSignature"): attrs["sparkle:edSignature"],
        "length": attrs["length"],
    })

    # Newest first, after the channel's own title, link and description.
    items = [item] + channel.findall("item")
    for old in channel.findall("item"):
        channel.remove(old)
    channel.extend(items[:MAX_ITEMS])

    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write("\n")
    print(f"{path}: added Headroom {version} (build {build}), {len(items[:MAX_ITEMS])} release(s) listed.")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    main(*sys.argv[1:])
