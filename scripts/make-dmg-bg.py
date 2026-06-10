#!/usr/bin/env python3
"""Generate the DMG backdrop shown in the Finder window when the DMG is
mounted. Two icon slots (app on left, Applications folder on right) are
positioned by AppleScript in make-dmg.sh; this image draws the labels and
an arrow between them.

Usage: scripts/make-dmg-bg.py [brand-display-name] [output-path]

The installer title ("Drag <name> into your Applications folder") is driven
by the brand display name so a rebrand flows through automatically:
an optional first argument overrides it, otherwise it is read from
``appDisplayName`` in QuotaMonitor/Core/Branding.swift (the single source of
truth), falling back to "Quota Monitor". The second argument overrides the
output path (default Resources/dmg-background.png)."""

import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent


def brand_display_name() -> str:
    """argv[1] override → appDisplayName in Branding.swift → default."""
    if len(sys.argv) >= 2 and sys.argv[1].strip():
        return sys.argv[1].strip()
    branding = ROOT / "QuotaMonitor" / "Core" / "Branding.swift"
    try:
        text = branding.read_text(encoding="utf-8")
    except OSError:
        return "Quota Monitor"
    m = re.search(r'appDisplayName\s*=\s*"([^"]+)"', text)
    return m.group(1).strip() if m else "Quota Monitor"


BRAND = brand_display_name()

W, H = 540, 380
BG = (246, 246, 247, 255)
INK = (28, 28, 30, 255)
DIM = (110, 110, 118, 255)
FAINT = (162, 162, 170, 255)
ARROW = (174, 178, 188, 255)

SF = "/System/Library/Fonts/SFNS.ttf"
title_font = ImageFont.truetype(SF, 18)
sub_font = ImageFont.truetype(SF, 12)
foot_font = ImageFont.truetype(SF, 10)

img = Image.new("RGBA", (W, H), BG)
d = ImageDraw.Draw(img)

def center_text(text, y, font, fill):
    w = d.textlength(text, font=font)
    d.text(((W - w) / 2, y), text, font=font, fill=fill)

center_text(f"Drag {BRAND} into your Applications folder", 28, title_font, INK)
center_text("First launch: right-click → Open", 60, sub_font, DIM)

# Arrow centered between the two icon slots (icons sit at y≈220 in
# AppleScript). Draw a flat right-pointing arrow.
ax0, ax1, ay = 220, 320, 210
d.rectangle([ax0, ay - 4, ax1 - 12, ay + 4], fill=ARROW)
d.polygon([(ax1 - 18, ay - 14), (ax1, ay), (ax1 - 18, ay + 14)], fill=ARROW)

center_text("ad-hoc signed · macOS will ask once on first launch", 345, foot_font, FAINT)

out = (Path(sys.argv[2]).resolve() if len(sys.argv) >= 3
       else ROOT / "Resources" / "dmg-background.png")
img.save(out, "PNG")
print(f"wrote {out} ({W}x{H})")
