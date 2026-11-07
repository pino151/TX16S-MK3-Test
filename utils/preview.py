#!/usr/bin/env python3
"""Preview an EdgeTX color-screen widget on the PC.

Runs the widget's Lua code (Lua 5.2, as on the radio) against a small mock of
the EdgeTX Lua API, and saves what it draws as PNG files at the MK3's 800x480
and the MK2's 480x272. Text uses the Roboto fonts at the pixel sizes EdgeTX
uses, so layouts come out close to the radio.

It also reports problems that are easy to miss on the radio:
  - Lua syntax errors in any script under WIDGETS/ and SCRIPTS/
  - drawing outside the widget's zone
  - lines EdgeTX would drop (an end outside the screen)
  - global variables the widget creates (all widgets share one Lua state)
  - string method calls like s:format() (use string.format(s, ...))
  - output names not re-read after background()

This checks layout and logic only. It is not a simulator, so still test in
Companion and on the radio.

Usage:
  pip install lupa pillow
  python3 utils/preview.py                  # WIDGETS/PreRace, both sizes
  python3 utils/preview.py --scale 2        # bigger PNGs for viewing

The first run downloads Roboto from the EdgeTX GitHub repo into utils/.fonts
(or point --fonts at radio/src/fonts/Roboto in an EdgeTX checkout).
Exits with status 1 if any problem was found.
"""

import argparse
import sys
import time
import urllib.request
from pathlib import Path

try:
    import lupa.lua52 as lupa52
except ImportError:
    sys.exit("Needs lupa with Lua 5.2: pip install lupa")
from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
FONT_CACHE = Path(__file__).resolve().parent / ".fonts"
FONT_URL = "https://raw.githubusercontent.com/EdgeTX/edgetx/main/radio/src/fonts/Roboto/"

# EdgeTX font index -> (bold, pixel size, line height, base line), per font
# set. Sizes from radio/src/fonts/lvgl/make_fonts.sh, heights from the
# generated lv_font_en_*.c files. 800x480 radios use "lrg", 480x272 "std".
FONT_SETS = {
    "std": {0: (False, 16, 21, 5), 1: (True, 16, 20, 4), 2: (False, 9, 12, 3),
            3: (False, 13, 17, 4), 4: (False, 24, 29, 6), 5: (True, 32, 40, 9),
            6: (True, 64, 69, 15), 7: (True, 48, 51, 11)},
    "lrg": {0: (False, 22, 27, 6), 1: (True, 22, 27, 6), 2: (False, 12, 17, 4),
            3: (False, 18, 23, 5), 4: (False, 33, 42, 9), 5: (True, 44, 55, 12),
            6: (True, 88, 93, 20), 7: (True, 66, 71, 15)},
}

# Flag bits as in radio/src/gui/colorlcd (libopenui_defines.h, colors.h).
INVERS, VCENTER, CENTER, RIGHT, SHADOWED, BLINK, RGB_FLAG = (
    0x01, 0x02, 0x04, 0x08, 0x80, 0x1000, 0x8000)
SOLID, DOTTED = 0xFF, 0x55


def rgb_flag(r, g, b):
    c565 = ((int(r) & 0xF8) << 8) | ((int(g) & 0xFC) << 3) | (int(b) >> 3)
    return (c565 << 16) | RGB_FLAG


def flag_rgb(flags):
    c = (int(flags) >> 16) & 0xFFFF
    r, g, b = (c >> 11) & 0x1F, (c >> 5) & 0x3F, c & 0x1F
    return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)


def menu_button_size(h):
    """EdgeTX's menu button, drawn over the top-left corner in App mode
    (mask_ui_bg_topbar_left.png: 45 px at 480x272, 62 px at 800x480)."""
    return 62 if h >= 480 else 45


# Literal colors from radio/src/gui/colorlcd/colors.cpp. Theme colors are
# mocked as their default values.
COLORS = {
    "BLACK": (0, 0, 0), "WHITE": (255, 255, 255), "LIGHTWHITE": (234, 234, 234),
    "LIGHTGREY": (192, 192, 192), "DARKGREY": (64, 64, 64), "GREY": (96, 96, 96),
    "RED": (255, 0, 0), "DARKRED": (160, 0, 0), "GREEN": (0, 255, 0),
    "DARKGREEN": (0, 160, 0), "BRIGHTGREEN": (0, 180, 60), "BLUE": (0, 0, 255),
    "DARKBLUE": (0, 0, 160), "YELLOW": (255, 255, 0), "LIGHTBROWN": (156, 109, 32),
    "DARKBROWN": (106, 72, 16), "ORANGE": (229, 100, 30),
    "COLOR_THEME_PRIMARY1": (0, 0, 0), "COLOR_THEME_PRIMARY2": (255, 255, 255),
    "COLOR_THEME_PRIMARY3": (12, 63, 102), "COLOR_THEME_SECONDARY1": (18, 94, 153),
    "COLOR_THEME_SECONDARY2": (182, 224, 242), "COLOR_THEME_SECONDARY3": (228, 238, 242),
    "COLOR_THEME_FOCUS": (20, 161, 229), "COLOR_THEME_EDIT": (0, 153, 9),
    "COLOR_THEME_ACTIVE": (255, 222, 0), "COLOR_THEME_WARNING": (224, 0, 0),
    "COLOR_THEME_DISABLED": (140, 140, 140), "CUSTOM_COLOR": (170, 85, 0),
}

CONSTANTS = {
    "STDSIZE": 0 << 8, "BOLD": 1 << 8, "TINSIZE": 2 << 8, "SMLSIZE": 3 << 8,
    "MIDSIZE": 4 << 8, "DBLSIZE": 5 << 8, "XXLSIZE": 6 << 8,
    "LEFT": 0, "INVERS": INVERS, "VCENTER": VCENTER, "CENTER": CENTER,
    "RIGHT": RIGHT, "SHADOWED": SHADOWED, "BLINK": BLINK,
    "SOLID": SOLID, "DOTTED": DOTTED,
    # Widget option types (values only need to be distinct here).
    "VALUE": 1, "SOURCE": 2, "COLOR": 3, "BOOL": 4, "STRING": 5, "TIMER": 6,
    "TEXT_SIZE": 7, "ALIGNMENT": 8, "SWITCH": 9, "SLIDER": 10, "CHOICE": 11,
}

# Radio data the scenarios use. CH1-CH4 in AETR order (stick numbers:
# 0 rudder, 1 elevator, 2 throttle, 3 aileron).
AETR = [3, 1, 2, 0]
NAMES = {4: "ARM", 5: "MODE", 6: "BEEPER", 7: "TURTLE", 11: "BLKBOX", 13: "VTXPIT"}
SCENARIOS = {
    # Throttle low, sticks centred, every aux switch low.
    "idle": {0: 0, 1: 0, 2: -1024, 3: 0, **{i: -1024 for i in range(4, 15)}},
    # Sticks deflected, switches in mixed positions, one output past 100%.
    "moving": {0: 620, 1: -410, 2: 300, 3: 1024, 4: 1024, 5: 0, 6: -1024, 7: 1024,
               8: 1300, 9: -600, 10: 0, 11: 1024, 12: -1024, 13: 512, 14: 1024},
}

LUA_SETUP = r"""
return function(sdroot, problem)
  function loadScript(path, mode, env)
    if env then
      return loadfile(sdroot .. path, "t", env)
    end
    return loadfile(sdroot .. path, "t")
  end
  -- Report s:method() calls, which EdgeTX does not reliably support.
  getmetatable("").__index = function(s, k)
    problem("string method call :" .. tostring(k) .. "(), use string." .. tostring(k) .. "(s, ...)")
    return string[k]
  end
  -- Record globals created from here on (all widgets share one Lua state).
  GLOBAL_WRITES = {}
  setmetatable(_G, { __newindex = function(t, k, v)
    GLOBAL_WRITES[#GLOBAL_WRITES + 1] = tostring(k)
    rawset(t, k, v)
  end })
end
"""

LUA_DEFAULT_OPTIONS = r"""
return function(def)
  local o = {}
  for _, opt in ipairs(def.options or {}) do
    o[opt[1]] = opt[3]
  end
  return o
end
"""


class Fonts:
    def __init__(self, font_dir, set_name):
        self.metrics = FONT_SETS[set_name]
        self.files = {False: find_font("Roboto-Regular.ttf", font_dir),
                      True: find_font("Roboto-Bold.ttf", font_dir)}
        self.cache = {}

    def get(self, flags):
        index = (int(flags) >> 8) & 0x0F
        bold, px, line_h, base = self.metrics.get(index, self.metrics[0])
        key = (bold, px)
        if key not in self.cache:
            path = self.files[bold]
            self.cache[key] = (ImageFont.truetype(str(path), px) if path
                               else ImageFont.load_default(px))
        return self.cache[key], line_h, base

    def width(self, text, flags):
        font, _, _ = self.get(flags)
        return int(round(font.getlength(text)))


def find_font(name, font_dir):
    for d in (font_dir, FONT_CACHE):
        if d and (Path(d) / name).exists():
            return Path(d) / name
    try:
        FONT_CACHE.mkdir(exist_ok=True)
        with urllib.request.urlopen(FONT_URL + name, timeout=20) as r:
            (FONT_CACHE / name).write_bytes(r.read())
        return FONT_CACHE / name
    except OSError as e:
        print(f"warning: could not get {name} ({e}); text widths will be rough")
        return None


class Screen:
    """One frame: the lcd.* drawing calls land here."""

    def __init__(self, w, h, fonts, problems):
        self.w, self.h = w, h
        # Magenta shows anything the widget leaves undrawn.
        self.img = Image.new("RGB", (w, h), (255, 0, 255))
        self.d = ImageDraw.Draw(self.img)
        self.fonts = fonts
        self.problems = problems
        self.texts = []
        self.text_boxes = []

    def check(self, what, x0, y0, x1, y1):
        if x0 < 0 or y0 < 0 or x1 > self.w or y1 > self.h:
            self.problems.add(f"{self.w}x{self.h}: {what} at ({x0},{y0})-({x1},{y1}) "
                              f"goes outside the zone")

    def drawText(self, x, y, text, flags=0, _invers=None):
        flags, x, y, text = int(flags or 0), int(x), int(y), str(text)
        font, line_h, base = self.fonts.get(flags)
        if flags & VCENTER:
            y -= line_h // 2
        width = self.fonts.width(text, flags)
        if flags & RIGHT:
            x -= width
        elif flags & CENTER:
            x -= width // 2
        self.check(f"text {text!r}", x, y, x + width, y + line_h)
        self.d.text((x, y + line_h - base), text, font=font, fill=flag_rgb(flags),
                    anchor="ls")
        self.texts.append(text)
        self.text_boxes.append((text, x, y, x + width, y + line_h))

    def app_mode_button(self):
        """Report text under EdgeTX's menu button, then draw the button."""
        size = menu_button_size(self.h)
        for text, x0, y0, _, _ in self.text_boxes:
            if x0 < size and y0 < size:
                self.problems.add(f"{self.w}x{self.h}: text {text!r} is under "
                                  f"EdgeTX's menu button")
        overlay = Image.new("RGBA", (size, size), (20, 161, 229, 200))
        self.img.paste(overlay, (0, 0), overlay)

    def sizeText(self, text, flags=0):
        _, line_h, _ = self.fonts.get(flags or 0)
        return self.fonts.width(str(text), flags or 0), line_h

    def drawFilledRectangle(self, x, y, w, h, flags=0, _opacity=0):
        x, y, w, h = int(x), int(y), int(w), int(h)
        if w <= 0 or h <= 0:
            return
        self.check("filled rectangle", x, y, x + w, y + h)
        self.d.rectangle([x, y, x + w - 1, y + h - 1], fill=flag_rgb(flags or 0))

    def drawRectangle(self, x, y, w, h, flags=0, t=1, _opacity=0):
        x, y, w, h, t = int(x), int(y), int(w), int(h), int(t or 1)
        if w <= 0 or h <= 0:
            return
        self.check("rectangle", x, y, x + w, y + h)
        self.d.rectangle([x, y, x + w - 1, y + h - 1], outline=flag_rgb(flags or 0), width=t)

    def drawLine(self, x1, y1, x2, y2, pattern=SOLID, flags=0):
        x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
        if min(x1, x2) < 0 or min(y1, y2) < 0 or max(x1, x2) >= self.w or max(y1, y2) >= self.h:
            self.problems.add(f"{self.w}x{self.h}: line ({x1},{y1})-({x2},{y2}) has an end "
                              f"outside the screen; EdgeTX may not draw it")
        pattern, color = int(pattern or SOLID), flag_rgb(flags or 0)
        dx, dy = abs(x2 - x1), -abs(y2 - y1)
        sx, sy = (1 if x2 >= x1 else -1), (1 if y2 >= y1 else -1)
        err, i = dx + dy, 0
        while True:
            if (pattern >> (i % 8)) & 1 and 0 <= x1 < self.w and 0 <= y1 < self.h:
                self.img.putpixel((x1, y1), color)
            if x1 == x2 and y1 == y2:
                break
            e2, i = 2 * err, i + 1
            if e2 >= dy:
                err, x1 = err + dy, x1 + sx
            if e2 <= dx:
                err, y1 = err + dx, y1 + sy

    def drawCircle(self, x, y, r, flags=0):
        x, y, r = int(x), int(y), int(r)
        self.check("circle", x - r, y - r, x + r + 1, y + r + 1)
        self.d.ellipse([x - r, y - r, x + r, y + r], outline=flag_rgb(flags or 0), width=1)

    def drawFilledCircle(self, x, y, r, flags=0):
        x, y, r = int(x), int(y), int(r)
        self.check("filled circle", x - r, y - r, x + r + 1, y + r + 1)
        self.d.ellipse([x - r, y - r, x + r, y + r], fill=flag_rgb(flags or 0))


class Radio:
    """Mock EdgeTX runtime: lcd.*, model.*, outputs and stick settings."""

    def __init__(self, lua, problems):
        self.lua = lua
        self.problems = problems
        self.screen = None
        self.outputs = {}
        self.names = dict(NAMES)
        g = lua.globals()
        for name, value in CONSTANTS.items():
            g[name] = value
        for name, rgb in COLORS.items():
            g[name] = rgb_flag(*rgb)
        draw = ["drawText", "sizeText", "drawFilledRectangle", "drawRectangle",
                "drawLine", "drawCircle", "drawFilledCircle"]
        lcd = {n: (lambda n: lambda *a: getattr(self.screen, n)(*a))(n) for n in draw}
        lcd["RGB"] = self.rgb
        lcd["exitFullScreen"] = lambda: None
        g.lcd = lua.table_from(lcd)
        g.model = lua.table_from({"getOutput": self.get_output})
        g.getOutputValue = lambda i: int(self.outputs.get(int(i), 0))
        g.defaultChannel = lambda stick: AETR.index(int(stick)) if int(stick) in AETR else None
        g.getStickMode = lambda: 2
        g.getTime = lambda: int(time.monotonic() * 100)

    def rgb(self, r, g=None, b=None):
        if g is None:
            r, g, b = (int(r) >> 16) & 0xFF, (int(r) >> 8) & 0xFF, int(r) & 0xFF
        return rgb_flag(r, g, b)

    def get_output(self, i):
        return self.lua.table_from({"name": self.names.get(int(i), "")})


def lua_files():
    for top in ("WIDGETS", "SCRIPTS"):
        yield from sorted((REPO / top).rglob("*.lua"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--widget", default="WIDGETS/PreRace", help="widget folder")
    ap.add_argument("--out", default="preview", help="output folder for the PNGs")
    ap.add_argument("--sizes", default="800x480,480x272", help="screen sizes to render")
    ap.add_argument("--scale", type=int, default=1, help="enlarge the PNGs")
    ap.add_argument("--fonts", help="folder with Roboto-Regular.ttf and Roboto-Bold.ttf")
    args = ap.parse_args()

    problems = set()
    lua = lupa52.LuaRuntime(unpack_returned_tuples=True)

    # Every script must compile as Lua 5.2.
    for path in lua_files():
        result = lua.globals().loadfile(path.as_posix())
        if isinstance(result, tuple) and result[0] is None:
            problems.add(f"syntax: {result[1]}")

    radio = Radio(lua, problems)
    lua.execute(LUA_SETUP)(REPO.as_posix(), lambda msg: problems.add(str(msg)))
    default_options = lua.execute(LUA_DEFAULT_OPTIONS)

    widget_dir = (REPO / args.widget).resolve()
    folder = widget_dir.name
    if len(folder) > 8:
        problems.add(f"widget folder name {folder!r} is longer than 8 characters")
    result = lua.globals().loadScript("/" + widget_dir.relative_to(REPO).as_posix() + "/main.lua")
    chunk = result[0] if isinstance(result, tuple) else result
    if chunk is None:
        sys.exit(f"cannot load {args.widget}/main.lua: {result[1]}")
    widget = chunk()
    if len(str(widget.name)) > 10:
        problems.add(f"widget name {widget.name!r} is longer than 10 characters")
    opts_def = widget.options
    if opts_def is not None:
        if len(opts_def) > 5:
            problems.add("more than 5 widget options")
        for opt in opts_def.values():
            if len(str(opt[1])) > 10 or " " in str(opt[1]):
                problems.add(f"option name {opt[1]!r}: max 10 characters, no spaces")

    out = REPO / args.out
    out.mkdir(exist_ok=True)
    written = []

    def render(w, h, fonts, scenario, light=False, wgt=None, opts=None):
        radio.outputs = SCENARIOS[scenario]
        radio.screen = Screen(w, h, fonts, problems)
        if wgt is None:
            opts = default_options(widget)
            opts["Light"] = 1 if light else 0
            zone = lua.table_from({"x": 0, "y": 0, "w": w, "h": h, "xabs": 0, "yabs": 0})
            wgt = widget.create(zone, opts)
        widget.refresh(wgt, None, None)
        return wgt, radio.screen

    for size in args.sizes.split(","):
        w, h = (int(v) for v in size.lower().split("x"))
        fonts = Fonts(args.fonts, "lrg" if w >= 800 else "std")
        frames = [("idle", False), ("moving", False), ("idle", True)]
        for scenario, light in frames:
            try:
                wgt, screen = render(w, h, fonts, scenario, light)
            except lupa52.LuaError as e:
                problems.add(f"{w}x{h} {scenario}: Lua error: {e}")
                continue
            screen.app_mode_button()  # the zone is the whole screen, at 0,0
            img = screen.img
            if args.scale > 1:
                img = img.resize((w * args.scale, h * args.scale), Image.NEAREST)
            name = f"{folder}-{w}x{h}-{scenario}{'-light' if light else ''}.png"
            img.save(out / name)
            written.append(out / name)

        # Lifecycle: names edited while the widget was hidden must show up.
        try:
            wgt, _ = render(w, h, fonts, "idle")
            radio.names[4] = "ARMED"
            widget.background(wgt)
            _, screen = render(w, h, fonts, "idle", wgt=wgt)
            if "ARMED" not in screen.texts:
                problems.add(f"{w}x{h}: output names not re-read after background()")
            # A zone too small for the layout must not crash.
            wgt.zone.w, wgt.zone.h = 200, 100
            render(200, 100, fonts, "idle", wgt=wgt)
        except lupa52.LuaError as e:
            problems.add(f"{w}x{h} lifecycle: Lua error: {e}")
        finally:
            radio.names = dict(NAMES)

    for name in lua.globals().GLOBAL_WRITES.values():
        problems.add(f"widget created a global variable: {name}")

    for path in written:
        print(f"wrote {path.relative_to(REPO) if path.is_relative_to(REPO) else path}")
    if problems:
        print(f"\n{len(problems)} problem(s):")
        for p in sorted(problems):
            print(f"  - {p}")
        return 1
    print("\nno problems found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
