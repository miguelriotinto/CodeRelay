#!/usr/bin/env python3
"""Generate every Code[Relay] icon from one vector master.

The mark is a two-tone tile: brushed silver over black, a 3 x 2 grid of dark
rounded squares in the silver (the top-middle one hollow, the active pane),
an orange status dot and the "relay" wordmark in the black. Each surface
gets the right variant:

  tile   full-bleed square        iOS app icon, Android legacy, store images
  mac    824 px tile on the 1024 grid, transparent margin   macOS 14-15 .icns, Linux
  fg     opaque square, art inside the 66/108 safe zone      Android adaptive
  logo   the macOS tile with a faint rim                    splash logos
  glyph  one even-odd path, single colour                   menu bar, tray

Sizes of 64 px and below drop the wordmark (a smudge at that size). The
splash logos keep it — the family look (Code[Whisper]'s tile carries
"whisper" the same way) — even though the app name prints under them. The wordmark
is Inter Regular (SIL Open Font License) baked into outlines, so rendering
needs no font. Everything is plain paths and linear gradients, which NSImage
renders. Run from the repo root on macOS:

    python3 Scripts/icons/make-icons.py
"""
import os, json, shutil, subprocess, tempfile

def f(v): return f"{v:.2f}".rstrip("0").rstrip(".")

def rrect(x, y, w, h, r):
    if r <= 0:
        return f"M{f(x)},{f(y)} L{f(x+w)},{f(y)} L{f(x+w)},{f(y+h)} L{f(x)},{f(y+h)} Z"
    return (f"M{f(x+r)},{f(y)} L{f(x+w-r)},{f(y)} A{f(r)},{f(r)} 0 0 1 {f(x+w)},{f(y+r)} "
            f"L{f(x+w)},{f(y+h-r)} A{f(r)},{f(r)} 0 0 1 {f(x+w-r)},{f(y+h)} L{f(x+r)},{f(y+h)} "
            f"A{f(r)},{f(r)} 0 0 1 {f(x)},{f(y+h-r)} L{f(x)},{f(y+r)} A{f(r)},{f(r)} 0 0 1 {f(x+r)},{f(y)} Z")

def half(top, s, split, r):
    """Top (silver) or bottom (black) part of an s x s tile with corner radius r."""
    if r <= 0:
        return (f"M0,0 L{f(s)},0 L{f(s)},{f(split)} L0,{f(split)} Z" if top else
                f"M0,{f(split)} L{f(s)},{f(split)} L{f(s)},{f(s)} L0,{f(s)} Z")
    if top:
        return (f"M0,{f(split)} L0,{f(r)} A{f(r)},{f(r)} 0 0 1 {f(r)},0 L{f(s-r)},0 "
                f"A{f(r)},{f(r)} 0 0 1 {f(s)},{f(r)} L{f(s)},{f(split)} Z")
    return (f"M0,{f(split)} L{f(s)},{f(split)} L{f(s)},{f(s-r)} A{f(r)},{f(r)} 0 0 1 {f(s-r)},{f(s)} "
            f"L{f(r)},{f(s)} A{f(r)},{f(r)} 0 0 1 0,{f(s-r)} Z")

# --- colour mark, in a 1024 tile (measured from the reference render) ---
SPLIT = 521
SQ_W, SQ_H, SQ_R, RING = 167, 160, 24, 13
COLS, ROWS = (220, 430, 639), (110, 299)
DOT = (170, 866, 35.5)
# "relay", Inter Regular outlines in font units (2048/em), left edge at 0, baseline 0.
RELAY = "M0 0V-1118H174V-946H186Q217 -1031 296 -1082Q376 -1134 476 -1134Q496 -1134 524 -1133Q551 -1132 567 -1131V-950Q559 -952 527 -956Q495 -960 459 -960Q338 -960 259 -886Q180 -813 180 -700V0ZM1241 24Q1079 24 962 -48Q844 -120 780 -249Q717 -378 717 -550Q717 -722 779 -853Q841 -984 954 -1058Q1068 -1132 1220 -1132Q1309 -1132 1396 -1102Q1482 -1073 1552 -1008Q1623 -942 1665 -835Q1707 -728 1707 -573V-498H899Q906 -323 1000 -230Q1093 -136 1242 -136Q1341 -136 1412 -180Q1484 -223 1515 -308L1689 -260Q1650 -133 1532 -54Q1413 24 1241 24ZM900 -650H1524Q1511 -793 1434 -882Q1358 -972 1220 -972Q1124 -972 1054 -927Q985 -882 945 -809Q905 -736 900 -650ZM2145 -1490V0H1965V-1490ZM2774 26Q2668 26 2582 -14Q2495 -54 2444 -131Q2393 -208 2393 -318Q2393 -414 2431 -474Q2469 -534 2532 -568Q2596 -603 2673 -620Q2750 -637 2828 -647Q2928 -660 2991 -667Q3054 -674 3084 -691Q3115 -708 3115 -749V-755Q3115 -859 3056 -916Q2997 -974 2881 -974Q2760 -974 2692 -922Q2624 -869 2598 -810L2425 -867Q2468 -969 2541 -1026Q2614 -1084 2702 -1108Q2790 -1132 2876 -1132Q2932 -1132 3004 -1118Q3075 -1105 3142 -1065Q3208 -1025 3252 -946Q3295 -868 3295 -737V0H3118V-152H3106Q3087 -113 3045 -72Q3003 -30 2936 -2Q2869 26 2774 26ZM2805 -133Q2905 -133 2974 -172Q3043 -211 3079 -274Q3115 -336 3115 -404V-559Q3104 -546 3067 -536Q3030 -525 2982 -517Q2935 -509 2890 -504Q2846 -498 2820 -495Q2755 -487 2698 -468Q2642 -448 2608 -410Q2574 -373 2574 -309Q2574 -222 2640 -178Q2705 -133 2805 -133ZM3593 405 3639 249 3658 254Q3741 276 3801 248Q3861 219 3902 99L3934 6L3507 -1118H3704L3942 -455Q3968 -382 3988 -310Q4009 -238 4028 -168Q4047 -238 4068 -310Q4088 -382 4114 -455L4354 -1118H4550L4059 167Q4008 300 3926 363Q3844 426 3725 426Q3677 426 3642 419Q3607 412 3593 405Z"
RELAY_X, RELAY_BASE, RELAY_K = 768.5, 885, 0.03115

DEFS = """<defs>
  <linearGradient id="silver" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e9eaed"/><stop offset="1" stop-color="#c3c5c9"/></linearGradient>
  <linearGradient id="edge" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ffffff" stop-opacity="0.18"/><stop offset="0.12" stop-color="#ffffff" stop-opacity="0"/><stop offset="0.82" stop-color="#000000" stop-opacity="0"/><stop offset="1" stop-color="#000000" stop-opacity="0.16"/></linearGradient>
  <linearGradient id="black" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#282828"/><stop offset="1" stop-color="#171717"/></linearGradient>
  <linearGradient id="well" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#141414"/><stop offset="1" stop-color="#232323"/></linearGradient>
</defs>"""

def tile_body(r, text, rim=False, bleed=None):
    """The mark in 1024 tile space. r: corner radius (0 = square). bleed: extend
    the two halves to cover this many units beyond each edge (adaptive icons)."""
    out = []
    if bleed:
        b = bleed
        out += [f'<rect x="{-b}" y="{-b}" width="{1024+2*b}" height="{SPLIT+b}" fill="url(#silver)"/>',
                f'<rect x="{-b}" y="{SPLIT}" width="{1024+2*b}" height="{1024-SPLIT+b}" fill="url(#black)"/>']
    else:
        top, bottom = half(True, 1024, SPLIT, r), half(False, 1024, SPLIT, r)
        out += [f'<path d="{top}" fill="url(#silver)"/>', f'<path d="{top}" fill="url(#edge)"/>',
                f'<path d="{bottom}" fill="url(#black)"/>',
                f'<path d="M0,1.5 L1024,1.5" stroke="#ffffff" stroke-opacity="0.55" stroke-width="3"/>' if r == 0 else
                f'<path d="M{r},1.5 L{1024-r},1.5" stroke="#ffffff" stroke-opacity="0.55" stroke-width="3"/>']
    out.append(f'<rect x="0" y="{SPLIT-3}" width="1024" height="3" fill="#000000" fill-opacity="0.22"/>')
    for row, y in enumerate(ROWS):
        for col, x in enumerate(COLS):
            outer = rrect(x, y, SQ_W, SQ_H, SQ_R)
            if (row, col) == (0, 1):   # the hollow, active pane
                inner = rrect(x + RING, y + RING, SQ_W - 2*RING, SQ_H - 2*RING, SQ_R - RING)
                out.append(f'<path d="{outer} {inner}" fill-rule="evenodd" fill="#151515"/>')
            else:
                out.append(f'<path d="{outer}" fill="url(#well)"/>')
    cx, cy, cr = DOT
    out.append(f'<circle cx="{cx}" cy="{cy}" r="{cr}" fill="#ff8800"/>')
    if text:
        out.append(f'<path d="{RELAY}" fill="#a8a9ad" transform="translate({RELAY_X} {RELAY_BASE}) scale({RELAY_K})"/>')
    if rim:
        out.append(f'<path d="{rrect(1.5, 1.5, 1021, 1021, max(r - 1.5, 0))}" fill="none" stroke="#ffffff" stroke-opacity="0.16" stroke-width="3"/>')
    return "\n".join(out)

def svg(body, comment, size=1024):
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n<!-- {comment} Generated by '
            f'Scripts/icons/make-icons.py; edit that, not this file. -->\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">\n'
            f'{DEFS}\n{body}\n</svg>\n')

def at(x, y, k, body): return f'<g transform="translate({f(x)} {f(y)}) scale({f(k)})">\n{body}\n</g>'

MAC_K = 824 / 1024          # macOS grid: 824 px tile at (100, 100); 185 px corners
MAC_R = 185 / MAC_K
FG_K = 60 / 108             # Android: mark inside 60 of the 108 dp (safe circle is 66)
VARIANTS = {
    "tile": lambda t: svg(tile_body(0, t), "Full-bleed app icon tile."),
    "mac":  lambda t: svg(at(100, 100, MAC_K, tile_body(MAC_R, t)), "Code[Relay] app icon on the macOS 824px grid."),
    "fg":   lambda t: svg(at(512 - 512*FG_K, 512 - 512*FG_K, FG_K, tile_body(0, t, bleed=512/FG_K)),
                          "Android adaptive foreground (opaque)."),
    "logo": lambda t: svg(at(100, 100, MAC_K, tile_body(MAC_R, t, rim=True)), "Splash logo."),
}

# --- single-colour glyph: the 3 x 2 grid, top-middle hollow (84 x 50.5 box) ---
G_W, G_H, G_GX, G_GY, G_R, G_RING = 24, 23, 6, 4.5, 5, 4.5
GLYPH_W, GLYPH_H = 3*G_W + 2*G_GX, 2*G_H + G_GY

def glyph_path():
    parts = []
    for row in range(2):
        for col in range(3):
            x, y = col * (G_W + G_GX), row * (G_H + G_GY)
            parts.append(rrect(x, y, G_W, G_H, G_R))
            if (row, col) == (0, 1):
                parts.append(rrect(x + G_RING, y + G_RING, G_W - 2*G_RING, G_H - 2*G_RING, G_R - G_RING/2))
    return " ".join(parts)

# --- outputs ---
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
def p(*parts): return os.path.join(ROOT, *parts)

def main():
    tmp = tempfile.mkdtemp()
    renderer = os.path.join(tmp, "render")
    subprocess.run(["swiftc", "-O", p("Scripts/icons/render.swift"), "-o", renderer], check=True)
    srcs = {}
    for name, make in VARIANTS.items():
        for text in (True, False):
            path = os.path.join(tmp, f"{name}{'' if text else '-notext'}.svg")
            open(path, "w").write(make(text)); srcs[(name, text)] = path

    def render(variant, out, px, opaque=False):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        text = px > 64
        subprocess.run([renderer, srcs[(variant, text)], out, str(px)] + (["opaque"] if opaque else []), check=True)

    # iOS: every file in the asset catalog, opaque full-bleed; Icon Composer layer for iOS 26+.
    ios = p("CodeRelayApp/Assets.xcassets/AppIcon.appiconset")
    for fn in os.listdir(ios):
        if fn.endswith(".png"): render("tile", os.path.join(ios, fn), int(fn[:-4]), opaque=True)
    icon = p("CodeRelayApp/AppIcon.icon")
    shutil.rmtree(os.path.join(icon, "Assets"), ignore_errors=True)
    render("tile", os.path.join(icon, "Assets", "icon.png"), 1024, opaque=True)
    for s, sfx in ((240, ""), (480, "@2x"), (720, "@3x")):
        render("logo", p(f"CodeRelayApp/Assets.xcassets/SplashLogo.imageset/SplashLogo{sfx}.png"), s)

    # macOS: an Icon Composer file for macOS 26+, compiled by Xcode into
    # Assets.car (CFBundleIconName). Without it macOS 26 draws the app small
    # inside a light frame, because an app whose icon comes only from an .icns
    # does not get the full Liquid Glass tile. Full-bleed art, like iOS: the
    # system applies the Mac shape, edge and lighting; the shadow matches
    # Code[Whisper]'s so the family reads the same in the Dock.
    mac_icon = p("CodeRelayMac/AppIcon.icon")
    shutil.rmtree(os.path.join(mac_icon, "Assets"), ignore_errors=True)
    render("tile", os.path.join(mac_icon, "Assets", "icon.png"), 1024, opaque=True)
    with open(os.path.join(mac_icon, "icon.json"), "w") as fh:
        json.dump({
            "fill": {"solid": "srgb:0.07000,0.07000,0.07000,1.00000"},
            "groups": [{
                "layers": [{"glass": False, "image-name": "icon.png", "name": "icon"}],
                "shadow": {"kind": "neutral", "opacity": 0.4},
                "translucency": {"enabled": False, "value": 0},
            }],
            "supported-platforms": {"squares": "shared"},
        }, fh, indent=2)
        fh.write("\n")
    # The prebuilt .icns stays as the icon for macOS 14 and 15 (CFBundleIconFile),
    # complete from 16 to 1024 px.
    iconset = os.path.join(tmp, "CodeRelayIcon.iconset")
    for s in (16, 32, 128, 256, 512):
        render("mac", os.path.join(iconset, f"icon_{s}x{s}.png"), s)
        render("mac", os.path.join(iconset, f"icon_{s}x{s}@2x.png"), s * 2)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", p("CodeRelayMac/CodeRelayIcon.icns")], check=True)
    h = 13; w = round(h * GLYPH_W / GLYPH_H)
    open(p("CodeRelayMac/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg"), "w").write(
        '<?xml version="1.0" encoding="UTF-8"?>\n<!-- The app icon\'s pane grid as a menu bar template '
        'image: macOS tints it for light/dark bars. Generated by Scripts/icons/make-icons.py. -->\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {f(GLYPH_W)} {f(GLYPH_H)}">\n'
        f'  <path fill="#000000" fill-rule="evenodd" d="{glyph_path()}"/>\n</svg>\n')

    # Android: legacy + round fallbacks, adaptive foreground, Compose splash, store sources.
    res = p("CodeRelayAndroid/app/src/main/res")
    for d, s in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        for fn in ("ic_launcher.png", "ic_launcher_round.png"):
            render("tile", os.path.join(res, f"mipmap-{d}", fn), s, opaque=True)
        render("fg", os.path.join(res, f"mipmap-{d}", "ic_launcher_foreground.png"), s * 9 // 4, opaque=True)
        render("tile", p(f"AppIcons/android/mipmap-{d}/ic_launcher.png"), s, opaque=True)
    render("logo", os.path.join(res, "drawable-nodpi", "splash_logo.png"), 512)
    render("tile", p("AppIcons/appstore.png"), 1024, opaque=True)
    render("tile", p("AppIcons/playstore.png"), 512, opaque=True)

    # Linux: scalable source + the 512 px PNG jpackage embeds.
    open(p("CodeRelayLinux/packaging/coderelay.svg"), "w").write(VARIANTS["mac"](True))
    render("mac", p("CodeRelayLinux/packaging/coderelay.png"), 512)

    print(f"glyph path (TrayIcon.kt GLYPH_PATH, {f(GLYPH_W)} x {f(GLYPH_H)}):\n" + glyph_path())
    shutil.rmtree(tmp)

if __name__ == "__main__":
    main()
