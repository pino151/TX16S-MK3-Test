#!/usr/bin/env python3
"""Preview an EdgeTX color-screen widget on the PC.

Runs the widget's Lua code (Lua 5.2, as on the radio) against a small mock of
the EdgeTX Lua API, and saves what it draws as PNG files at the MK3's 800x480
and the MK2's 480x272. Text uses the Roboto fonts at the pixel sizes EdgeTX
uses, so layouts come out close to the radio.

CRSF telemetry sensors and an ExpressLRS TX module (utils/fake_elrs.py: the
MK3's internal ELRS 4.x module at 800x480, the MK2's Ranger Micro on ELRS
3.x at 480x272) are simulated too, frame by frame on a simulated clock.

It also reports problems that are easy to miss on the radio:
  - Lua syntax errors in any script under WIDGETS/ and SCRIPTS/
  - drawing outside the widget's zone, text overlapping other text, and
    text under EdgeTX's App-mode menu button
  - lines EdgeTX would drop (an end outside the screen)
  - global variables the widget creates (all widgets share one Lua state)
  - string method calls like s:format() (use string.format(s, ...))
  - behaviour checks: output names, telemetry states, reading the ELRS
    settings (lost replies, re-reads, refresh tap, no module)

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
import urllib.request
from pathlib import Path

try:
    import lupa.lua52 as lupa52
except ImportError:
    sys.exit("Needs lupa with Lua 5.2: pip install lupa")
from PIL import Image, ImageDraw, ImageFont

import fake_elrs

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
    # Events (values only need to be distinct here).
    "EVT_TOUCH_FIRST": 0x8001, "EVT_TOUCH_TAP": 0x8002, "EVT_TOUCH_BREAK": 0x8003,
    "EVT_TOUCH_SLIDE": 0x8004, "EVT_VIRTUAL_ENTER": 0x8005, "EVT_VIRTUAL_EXIT": 0x8006,
}

# Radio data the scenarios use. CH1-CH4 in AETR order (stick numbers:
# 0 rudder, 1 elevator, 2 throttle, 3 aileron).
AETR = [3, 1, 2, 0]
NAMES = {4: "ARM", 5: "MODE", 6: "BEEPER", 7: "TURTLE", 8: "BLKBOX", 10: "VTXPIT"}

# Outputs: throttle low, sticks centred, every aux switch low.
OUT_IDLE = {0: 0, 1: 0, 2: -1024, 3: 0, **{i: -1024 for i in range(4, 15)}}
# Outputs: sticks deflected, switches in mixed positions, one past 100%.
OUT_MOVING = {0: 620, 1: -410, 2: 300, 3: 1024, 4: 1024, 5: 0, 6: -1024, 7: 1024,
              8: 1300, 9: -600, 10: 0, 11: 1024, 12: -1024, 13: 512, 14: 1024}
# CRSF telemetry as EdgeTX names it. ANT is 1 or 2 for ELRS. None = no link.
TLM_GOOD = {"RQly": 100, "1RSS": -38, "2RSS": -41, "ANT": 1, "RxBt": 16.6, "FM": "ACRO*"}
TLM_POOR = {"RQly": 62, "1RSS": -95, "2RSS": -88, "ANT": 2, "RxBt": 22.3, "FM": "ANGL!"}
SCENARIOS = {
    "idle": (OUT_IDLE, None),
    "linked": (OUT_MOVING, TLM_GOOD),
    "warnings": (OUT_IDLE, TLM_POOR),
}
SENSOR_IDS = {name: 300 + i for i, name in enumerate(TLM_GOOD)}

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
        box = (x, y, x + width, y + line_h)
        for other, *b in self.text_boxes:
            if text and other and box[0] < b[2] and b[0] < box[2] and box[1] < b[3] and b[1] < box[3]:
                self.problems.add(f"{self.w}x{self.h}: text {text!r} overlaps {other!r}")
        self.d.text((x, y + line_h - base), text, font=font, fill=flag_rgb(flags),
                    anchor="ls")
        self.texts.append(text)
        self.text_boxes.append((text, *box))

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
    """Mock EdgeTX runtime: lcd.*, model.*, outputs, stick settings, CRSF
    telemetry sensors and the CRSF link to a (fake) TX module."""

    def __init__(self, lua, problems):
        self.lua = lua
        self.problems = problems
        self.screen = None
        self.outputs = {}
        self.names = dict(NAMES)
        self.clock = 0             # getTime() ticks; advanced per frame
        self.telemetry = None      # sensor name -> value while linked
        self.discovered = set()    # sensors EdgeTX has created so far
        self.last = {}             # last value of each sensor
        self.module = None         # fake_elrs.FakeElrs, or None: no CRSF module
        self.fc = None             # fake_elrs.FakeFc: the quad's FC, reached while linked
        self.crsf_in = []          # (ready at tick, command, data) on the way in
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
        g.getTime = lambda: self.clock
        g.getRSSI = self.get_rssi
        g.getFieldInfo = self.get_field_info
        g.getSourceValue = self.get_source_value
        g.crossfireTelemetryPush = self.crsf_push
        g.crossfireTelemetryPop = self.crsf_pop

    def set_module(self, module):
        """Plug in a fake module (or None). An unrelated ELRS status frame is
        already queued, as the widget must skip frames it didn't ask for."""
        self.module = module
        self.crsf_in = [(0, fake_elrs.ELRS_STATUS, [0xEA, 0xEE, 0, 0, 0, 0, 0])] if module else []

    def crsf_push(self, command=None, data=None):
        """nil without a CRSF module, else true. Module replies arrive a tick
        later. MSP requests go over the link to the FC (only while linked);
        its replies come back slower, one telemetry chunk at a time."""
        if self.module is None:
            return None
        if command is None:
            return True
        command = int(command)
        payload = [int(data[i]) for i in range(1, len(data) + 1)]
        if command in (fake_elrs.MSP_REQ, fake_elrs.MSP_WRITE) and payload[0] == fake_elrs.FC:
            if self.telemetry and self.fc:
                for n, reply in enumerate(self.fc.handle(payload)):
                    self.crsf_in.append((self.clock + 15 + 5 * n, *reply))
            return True
        sends = self.module.vtx_sends
        for reply in self.module.handle(command, payload):
            self.crsf_in.append((self.clock + 1, *reply))
        if self.module.vtx_sends > sends:
            self.vtx_admin_to_fc()
        return True

    def vtx_admin_to_fc(self):
        """ELRS VTX Admin sends its setting to the FC (if linked and on)."""
        band, ch, power = self.module.vtx_admin()
        if self.telemetry and self.fc and band:
            self.fc.apply_vtx_admin(band, ch, power)

    def crsf_pop(self):
        for i, (ready, command, data) in enumerate(self.crsf_in):
            if ready <= self.clock:
                del self.crsf_in[i]
                return command, self.lua.table_from(data)
        return None

    def set_telemetry(self, values):
        """Start (dict) or stop (None) the link. Like EdgeTX, sensors are
        created when their first value arrives and stay afterwards."""
        was_linked = bool(self.telemetry)
        self.telemetry = values
        if values:
            self.discovered.update(values)
            self.last.update(values)
            if not was_linked and self.module:
                self.vtx_admin_to_fc()  # ELRS sends VTX Admin when a quad connects

    def get_rssi(self):
        lq = (self.telemetry or {}).get("RQly", 0)
        return min(99, lq), 45, 42

    def get_field_info(self, name):
        name = str(name)
        if name not in self.discovered:
            return None
        return self.lua.table_from({"id": SENSOR_IDS[name], "name": name, "desc": ""})

    def get_source_value(self, src):
        """value, isCurrent, isFresh - or nothing for an unknown sensor."""
        name = next((n for n, i in SENSOR_IDS.items() if i == int(src)), None)
        if name is None or name not in self.discovered:
            return None
        if self.telemetry and name in self.telemetry:
            return self.telemetry[name], True, True
        return self.last.get(name, 0), False, False

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
    step = 5  # ticks per frame: EdgeTX calls refresh() about every 50 ms
    tap = CONSTANTS["EVT_TOUCH_TAP"]

    def new_widget(w, h, light=False):
        opts = default_options(widget)
        opts["Light"] = 1 if light else 0
        zone = lua.table_from({"x": 0, "y": 0, "w": w, "h": h, "xabs": 0, "yabs": 0})
        return widget.create(zone, opts)

    def run(wgt, w, h, fonts, frames=4, outputs=OUT_IDLE, telemetry=None, event=None, touch=None,
            fullscreen=False):
        """Set the radio's state, then call refresh() `frames` times, one step
        apart. The first call gets `event`, and `touch` as (x, y). In
        fullscreen the others get event 0, otherwise nil (as EdgeTX does)."""
        radio.outputs = outputs
        radio.set_telemetry(telemetry)
        for i in range(frames):
            radio.clock += step
            radio.screen = Screen(w, h, fonts, problems)
            ev = event if i == 0 else (0 if fullscreen else None)
            ts = lua.table_from({"x": touch[0], "y": touch[1], "tapCount": 1}) if ev and touch else None
            widget.refresh(wgt, ev, ts)
        return radio.screen

    def fresh_radio(module=None, fc=None):
        radio.names = dict(NAMES)
        radio.discovered, radio.last, radio.telemetry = set(), {}, None
        radio.set_module(module)
        radio.fc = fc

    def lua_list(table):
        return [table[i] for i in range(1, len(table) + 1)]

    def expect(screen, text, what):
        if text not in screen.texts:
            problems.add(f"{screen.w}x{screen.h}: {what}: no {text!r} on screen")

    def guarded(label, check):
        try:
            check()
        except lupa52.LuaError as e:
            problems.add(f"{label}: Lua error: {e}")

    for size in args.sizes.split(","):
        w, h = (int(v) for v in size.lower().split("x"))
        fonts = Fonts(args.fonts, "lrg" if w >= 800 else "std")
        # The MK3's internal module, or the MK2's Ranger Micro, and what the
        # ELRS panel should then show.
        # The quad: Betaflight with an HDZero-style VTX table, on R3 (MK3,
        # whose VTX Admin is R3) or R1 (MK2, whose VTX Admin is off).
        if w >= 800:
            make_module = fake_elrs.mk3_internal
            elrs_texts = ["500Hz", "2.4G", "250mW", "Dyn", "Std", "1:64"]
            make_fc = lambda **kw: fake_elrs.FakeFc(**{"band": 5, "ch": 3, **kw})
        else:
            make_module = fake_elrs.mk2_ranger_micro
            elrs_texts = ["250Hz", "100mW", "1:16", "5859bps"]
            make_fc = lambda **kw: fake_elrs.FakeFc(**{"band": 5, "ch": 1, **kw})

        def save(screen, label):
            img = screen.img
            if args.scale > 1:
                img = img.resize((w * args.scale, h * args.scale), Image.NEAREST)
            name = f"{folder}-{w}x{h}-{label}.png"
            img.save(out / name)
            written.append(out / name)

        def screenshot(scenario, light):
            fresh_radio(make_module(), make_fc())
            outputs, telemetry = SCENARIOS[scenario]
            wgt = new_widget(w, h, light)
            screen = run(wgt, w, h, fonts, frames=80, outputs=outputs, telemetry=telemetry)
            screen.app_mode_button()  # the zone is the whole screen, at 0,0
            save(screen, scenario + ("-light" if light else ""))

        def tap_on(wgt, rect, frames=2):
            """A tap in the middle of a layout rectangle, in fullscreen. The
            outputs and the link (telemetry) stay as they are."""
            centre = (int(rect.x + rect.w // 2), int(rect.y + rect.h // 2))
            return run(wgt, w, h, fonts, frames=frames, outputs=radio.outputs,
                       telemetry=radio.telemetry, event=tap, touch=centre, fullscreen=True)

        def check_telemetry():
            fresh_radio(make_module())
            wgt = new_widget(w, h)
            s = run(wgt, w, h, fonts)
            expect(s, "NO LINK", "no telemetry yet")
            tlm = dict(TLM_GOOD, RxBt=16.8)
            s = run(wgt, w, h, fonts, telemetry=tlm)
            expect(s, "4S 16.8V", "cell count from a full 4S pack")
            expect(s, "READY", "Betaflight '*' suffix means ready to arm")
            s = run(wgt, w, h, fonts, telemetry=dict(tlm, RxBt=13.2))
            expect(s, "4S 13.2V", "cell count kept while the pack sags")
            s = run(wgt, w, h, fonts)
            expect(s, "NO LINK", "link lost")
            s = run(wgt, w, h, fonts, telemetry=dict(tlm, RxBt=25.2, FM="AIR"))
            expect(s, "6S 25.2V", "cell count worked out again after a pack swap")
            expect(s, "ARMED", "no suffix means armed")
            s = run(wgt, w, h, fonts, telemetry=dict(tlm, RxBt=0.1, FM="!FS!"))
            expect(s, "NO PACK", "FC on USB power")
            expect(s, "FAILSAFE", "Betaflight failsafe")
            # Output names edited while the widget was hidden must show up.
            radio.names[4] = "ARMSW"
            widget.background(wgt)
            s = run(wgt, w, h, fonts)
            if wgt.lay.compact:
                s = tap_on(wgt, wgt.lay.mid)  # the names are on the aux page
            expect(s, "ARMSW", "output names re-read after background()")
            # A zone too small for the layout must not crash.
            wgt.zone.w, wgt.zone.h = 200, 100
            run(wgt, 200, 100, fonts)

        def check_elrs():
            module = make_module()
            fresh_radio(module)
            wgt = new_widget(w, h)
            s = run(wgt, w, h, fonts, frames=80)
            for text in elrs_texts:
                expect(s, text, "ELRS setting read from the module")
            # The scan stops after the last field it needs, and only reads
            # every chunk of the fields it keeps.
            names = {f["name"] for f in module.fields}
            kept = {module.id_of(n) for n in ("RF Band", "Packet Rate", "Telem Ratio",
                                              "Max Power", "Dynamic", "Band", "Band/Enable",
                                              "Channel", "Pwr Lvl", "Send VTx") if n in names}
            if max(i for i, _ in module.reads) > max(kept):
                problems.add(f"{w}x{h}: the ELRS scan read past the fields it needs")
            if {i for i, c in module.reads if c > 0} - kept:
                problems.add(f"{w}x{h}: the ELRS scan read whole fields it doesn't need")
            # Settings changed while a tool ran are read again afterwards.
            module.set("Max Power", 5)
            radio.clock += 300
            s = run(wgt, w, h, fonts, frames=40)
            expect(s, "500mW", "ELRS settings re-read after a tool ran")
            # A tap on the ELRS panel (in fullscreen) reads everything again.
            module.set("Telem Ratio", 1)
            r = wgt.lay.elrs
            centre = (int(r.x + r.w // 2), int(r.y + r.h // 2))
            s = run(wgt, w, h, fonts, frames=80, event=tap, touch=centre)
            expect(s, "Off", "ELRS settings re-read after a tap on the panel")
            # A lost reply is asked for again.
            module = make_module()
            module.drop = {(module.id_of("Telem Ratio"), 0)}
            fresh_radio(module)
            s = run(new_widget(w, h), w, h, fonts, frames=120)
            expect(s, elrs_texts[-2], "a lost ELRS reply is asked for again")
            # No CRSF module, a module that doesn't answer, one that isn't ELRS.
            for module, text in ((None, "NO MODULE"), (make_module(silent=True), "NO REPLY"),
                                 (make_module(serial=b"TBS\0"), "NOT ELRS")):
                fresh_radio(module)
                s = run(new_widget(w, h), w, h, fonts, frames=100)
                expect(s, text, "ELRS panel message")

        def check_vtx():
            module = make_module()
            band = "Band/Enable" if "Band/Enable" in {f["name"] for f in module.fields} else "Band"
            fresh_radio(module)
            wgt = new_widget(w, h)
            run(wgt, w, h, fonts, frames=80, fullscreen=True)
            # A tap on the VIDEO panel opens the picker; CANCEL sends nothing.
            s = tap_on(wgt, wgt.lay.video)
            expect(s, "CANCEL", "VTX picker opens on a tap on the VIDEO panel")
            save(s, "picker")
            tap_on(wgt, wgt.pick.cancel)
            if module.writes or wgt.vtx.ui != "main":
                problems.add(f"{w}x{h}: CANCEL in the VTX picker didn't just close it")
            # Choose F4 at power 2, SEND, then BACK and SEND again, then CONFIRM.
            tap_on(wgt, wgt.lay.video)
            for rect in (wgt.pick.rows[1][2], wgt.pick.rows[2][4], wgt.pick.rows[3][3]):
                tap_on(wgt, rect)
            s = tap_on(wgt, wgt.pick.ok)
            expect(s, "CONFIRM", "SEND asks for confirmation")
            expect(s, "F4  5800MHz  PWR 2", "the confirmation shows the choice")
            expect(s, "ELRS sends it to every quad that connects,", "the confirmation explains")
            save(s, "confirm")
            s = tap_on(wgt, wgt.pick.cancel)
            expect(s, "SEND", "BACK returns to the picker")
            tap_on(wgt, wgt.pick.ok)
            s = tap_on(wgt, wgt.pick.ok, frames=60)
            wanted = [(band, 4), ("Channel", 4), ("Pwr Lvl", 2), ("Send VTx", 1)]
            if module.writes != wanted:
                problems.add(f"{w}x{h}: VTX send wrote {module.writes}, expected {wanted}")
            if wgt.vtx.state != "sent":
                problems.add(f"{w}x{h}: VTX send not confirmed by reading it back "
                             f"(state {wgt.vtx.state})")
            expect(s, "F4", "the VIDEO panel shows the new channel")
            # Leaving fullscreen closes the picker.
            tap_on(wgt, wgt.lay.video)
            run(wgt, w, h, fonts, frames=2)
            if wgt.vtx.ui != "main":
                problems.add(f"{w}x{h}: the VTX picker stayed open after leaving fullscreen")
            # A module that ignores the writes: the send fails.
            module = make_module(read_only=True)
            fresh_radio(module)
            wgt = new_widget(w, h)
            run(wgt, w, h, fonts, frames=80, fullscreen=True)
            tap_on(wgt, wgt.lay.video)
            tap_on(wgt, wgt.pick.rows[2][4])
            tap_on(wgt, wgt.pick.ok)
            tap_on(wgt, wgt.pick.ok, frames=60)
            if wgt.vtx.state != "failed":
                problems.add(f"{w}x{h}: a VTX send the module ignored wasn't reported as failed")
            # Without a module there's nothing to set, so the picker stays shut.
            fresh_radio(None)
            wgt = new_widget(w, h)
            run(wgt, w, h, fonts, frames=10, fullscreen=True)
            tap_on(wgt, wgt.lay.video)
            if wgt.vtx.ui != "main":
                problems.add(f"{w}x{h}: the VTX picker opened without a module")

        def check_fc():
            module, fc = make_module(), make_fc()
            fresh_radio(module, fc)
            wgt = new_widget(w, h)
            linked = dict(TLM_GOOD)
            s = run(wgt, w, h, fonts, frames=120, telemetry=linked, fullscreen=True)
            strip = wgt.vtx.strip
            admin = module.vtx_admin()[0]
            want = "R3" if admin else "R1"
            expect(s, want, "the FC's VTX channel in the QUAD strip")
            expect(s, "5732" if admin else "5658", "the FC's VTX frequency")
            if strip.level != (1 if admin else 0):
                problems.add(f"{w}x{h}: FC VTX cell level {strip.level}, expected "
                             f"{'green: it matches VTX Admin' if admin else 'neutral: VTX Admin off'}")
            # The picker uses the FC's table: no empty bands, its power labels,
            # and channels it doesn't have greyed out (and ignored).
            if lua_list(wgt.vtx.bandLabels) != ["R", "F", "E"]:
                problems.add(f"{w}x{h}: picker bands {lua_list(wgt.vtx.bandLabels)} not from the FC table")
            if lua_list(wgt.vtx.powerLabels) != ["-", "25", "200"]:
                problems.add(f"{w}x{h}: picker powers {lua_list(wgt.vtx.powerLabels)} not from the FC table")
            tap_on(wgt, wgt.lay.video)
            f = lua_list(wgt.vtx.bandLabels).index("F") + 1
            tap_on(wgt, wgt.pick.rows[1][f])
            if [wgt.vtx.chanOk[c] for c in range(1, 9)] != [False, True, False, True] + [False] * 4:
                problems.add(f"{w}x{h}: band F's channels not greyed out as in the FC table")
            tap_on(wgt, wgt.pick.rows[2][1])  # F1 doesn't exist: ignored
            tap_on(wgt, wgt.pick.rows[2][4])
            tap_on(wgt, wgt.pick.rows[3][2])  # 25
            s = tap_on(wgt, wgt.pick.ok)
            expect(s, "F4  5800MHz  PWR 25", "picker choice with the FC's power label")
            save(s, "confirm-fc")
            # Sending while linked: the FC takes it, and turns green when read back.
            s = tap_on(wgt, wgt.pick.ok, frames=120)
            if (fc.band, fc.ch) != (4, 4):
                problems.add(f"{w}x{h}: the FC didn't get F4 (has {fc.band}, {fc.ch})")
            expect(s, "F4", "the FC's new channel after a send")
            if wgt.vtx.strip.level != 1:
                problems.add(f"{w}x{h}: FC VTX cell not green after a send it took")
            save(s, "linked-sent")
            # The FC on another channel than VTX Admin, then in pit mode, then
            # without a VTX: each shows yellow at the next read.
            fc.ch = 5
            radio.clock += 1000
            s = run(wgt, w, h, fonts, frames=30, telemetry=linked)
            expect(s, "F5", "the FC's channel when it differs from VTX Admin")
            if wgt.vtx.strip.level != 2:
                problems.add(f"{w}x{h}: FC VTX cell not yellow when it differs from VTX Admin")
            fc.pit = 1
            radio.clock += 1000
            s = run(wgt, w, h, fonts, frames=30, telemetry=linked)
            expect(s, "PIT", "VTX in pit mode")
            fc.vtx_type = 255
            radio.clock += 1000
            s = run(wgt, w, h, fonts, frames=30, telemetry=linked)
            expect(s, "NO VTX", "FC without a VTX")
            # A different quad after the link drops; its replies come in small
            # chunks and the first answer is lost.
            run(wgt, w, h, fonts, frames=10)
            fc = make_fc(ch=7, chunk=12)
            fc.drop = {fake_elrs.MSP_VTX_CONFIG}
            radio.fc = fc
            s = run(wgt, w, h, fonts, frames=200, telemetry=linked, fullscreen=True)
            # VTX Admin is F4 since the send, so ELRS gives the new quad F4.
            expect(s, "F4", "VTX Admin's channel on a newly connected quad")
            if wgt.vtx.strip.level != 1:
                problems.add(f"{w}x{h}: new quad on VTX Admin's channel not shown green")
            if lua_list(wgt.vtx.bandLabels) != ["R", "F", "E"]:
                problems.add(f"{w}x{h}: VTX table not read from chunked MSP replies")
            tap_on(wgt, wgt.lay.video)
            save(tap_on(wgt, wgt.lay.video), "picker-fc")

        def check_pages():
            fresh_radio(make_module(), make_fc())
            wgt = new_widget(w, h)
            run(wgt, w, h, fonts, frames=80, outputs=OUT_MOVING, telemetry=dict(TLM_GOOD),
                fullscreen=True)
            if not wgt.lay.compact:
                tap_on(wgt, wgt.lay.mid)
                if wgt.page != "main":
                    problems.add(f"{w}x{h}: a full-size layout switched pages")
                return
            s = tap_on(wgt, wgt.lay.mid)
            expect(s, "BEEPER", "compact layout: a tap on the middle shows the aux page")
            expect(s, "TAP TO RETURN", "compact layout: the aux page says how to go back")
            save(s, "aux")
            s = tap_on(wgt, wgt.lay.mid)
            expect(s, "READY", "compact layout: a tap on the aux page returns")
            tap_on(wgt, wgt.lay.mid)
            run(wgt, w, h, fonts, frames=2, telemetry=radio.telemetry)  # fullscreen left
            if wgt.page != "main":
                problems.add(f"{w}x{h}: the aux page stayed after leaving fullscreen")

        for scenario, light in (("idle", False), ("linked", False), ("warnings", False),
                                ("linked", True)):
            guarded(f"{w}x{h} {scenario}", lambda: screenshot(scenario, light))
        guarded(f"{w}x{h} telemetry checks", check_telemetry)
        guarded(f"{w}x{h} ELRS checks", check_elrs)
        guarded(f"{w}x{h} VTX checks", check_vtx)
        guarded(f"{w}x{h} FC checks", check_fc)
        guarded(f"{w}x{h} page checks", check_pages)
        fresh_radio()

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
