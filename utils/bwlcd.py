"""EdgeTX's black-and-white LCD (128x64 radios such as the TX12), for the
PC preview: the lcd.* Lua functions drawing into a 1-bit image with the
radio's own bitmap fonts.

Ported from the EdgeTX source so text comes out pixel for pixel:
  radio/src/gui/common/stdlcd/lcd_common.cpp  (fonts, characters)
  radio/src/gui/128x64/lcd.cpp                (text, points, lines)
  radio/src/lua/api_stdlcd.cpp                (the Lua functions)
  tools/encode-font.py                        (font PNG -> font data)
"""

import urllib.request
from pathlib import Path

from PIL import Image

FONT_URL = "https://raw.githubusercontent.com/EdgeTX/edgetx/main/radio/src/fonts/std/"
LCD_W, LCD_H = 128, 64

# Flags, radio/src/gui/common/stdlcd/lcd_common.h.
BLINK, INVERS, RIGHT, FIXEDWIDTH, CENTERED, BOLD = 0x01, 0x02, 0x04, 0x10, 0x20, 0x40
FORCE, ERASE, ROUND = 0x02, 0x04, 0x08
SMLSIZE, MIDSIZE, DBLSIZE, XXLSIZE = 0x0200, 0x0300, 0x0400, 0x0500
SOLID, DOTTED = 0xFF, 0x55

# What EdgeTX gives Lua on these radios (api_general.cpp). No VCENTER, no
# colours, no lcd.sizeText and no circles.
CONSTANTS = {
    "LCD_W": LCD_W, "LCD_H": LCD_H,
    "XXLSIZE": XXLSIZE, "DBLSIZE": DBLSIZE, "MIDSIZE": MIDSIZE, "SMLSIZE": SMLSIZE,
    "BOLD": BOLD, "BLINK": BLINK, "INVERS": INVERS, "RIGHT": RIGHT, "LEFT": 0,
    "CENTER": CENTERED, "FIXEDWIDTH": FIXEDWIDTH,
    "FORCE": FORCE, "ERASE": ERASE, "ROUND": ROUND, "SOLID": SOLID, "DOTTED": DOTTED,
    # Keys of a radio with a scroll wheel (lua_keys.jinja). Values only need
    # to be distinct here.
    "EVT_VIRTUAL_PREV": 0x101, "EVT_VIRTUAL_NEXT": 0x102, "EVT_VIRTUAL_DEC": 0x101,
    "EVT_VIRTUAL_INC": 0x102, "EVT_VIRTUAL_ENTER": 0x103, "EVT_VIRTUAL_ENTER_LONG": 0x104,
    "EVT_VIRTUAL_EXIT": 0x105, "EVT_VIRTUAL_MENU": 0x106,
}

# name -> (file, cell width, pattern height, rows per cell in the PNG)
FONT_FILES = {
    "std": ("font_05x07.png", 5, 7, 8),
    "sml": ("font_04x06.png", 5, 6, 7),
    "mid": ("font_08x10.png", 8, 12, 12),
    "dbl": ("font_10x14_compressed.png", 10, 16, 16),
    "bold": ("font_05x07_B_compressed.png", 5, 7, 8),
}


def fetch(name, font_dir, cache):
    for d in (font_dir, cache):
        if d and (Path(d) / name).exists():
            return Path(d) / name
    cache.mkdir(exist_ok=True)
    with urllib.request.urlopen(FONT_URL + name, timeout=20) as r:
        (cache / name).write_bytes(r.read())
    return cache / name


def encode(path, cell_w, step):
    """tools/encode-font.py: a list of characters, each a list of columns,
    each column a list of bytes (bit set = pixel on). A column of 0xFF
    bytes is unused; the fonts are proportional."""
    image = Image.open(path).convert("L")
    width, height = image.size
    columns = []
    for y in range(0, height, step):
        for x in range(width):
            col, blank = [], True
            for part in range(0, step, 8):
                value = 0
                for z in range(min(8, step)):
                    if part + z < step:
                        if image.getpixel((x, y + part + z)) == 0:
                            value += 1 << z
                        else:
                            blank = False
                col.append(value)
            if blank:
                col = [0xFF] * len(col)  # all black in the PNG marks "unused"
            columns.append(col)
    return [columns[i:i + cell_w] for i in range(0, len(columns), cell_w)]


class Fonts:
    def __init__(self, font_dir, cache):
        self.fonts = {}
        for key, (name, cell_w, height, step) in FONT_FILES.items():
            self.fonts[key] = (encode(fetch(name, font_dir, cache), cell_w, step), height)

    def pattern(self, c, flags):
        """getCharPattern(): (columns, height, flags) for one character."""
        size = flags & 0x0700
        remapped = 0
        if size == DBLSIZE or flags & BOLD:
            if "," <= c <= ":":
                remapped = ord(c) - ord(",") + 1
            elif "A" <= c <= "Z":
                remapped = ord(c) - ord("A") + 16
            elif "a" <= c <= "z":
                remapped = ord(c) - ord("a") + 42
            elif c == "_":
                remapped = 4
            elif c != " ":
                flags &= ~BOLD
        if size == DBLSIZE:
            key, index = "dbl", remapped
        elif size == 0 and flags & BOLD:
            key, index = "bold", remapped
        else:
            key = {0: "std", SMLSIZE: "sml", MIDSIZE: "mid"}.get(size, "std")
            index = ord(c) - 0x20
        chars, height = self.fonts[key]
        if not 0 <= index < len(chars):
            index = 0
        return chars[index], height, flags

    def char_width(self, c, flags):
        cols, _, _ = self.pattern(c, flags)
        return sum(1 for col in cols if any(b != 0xFF for b in col))

    def text_width(self, text, flags):
        """getTextWidth(): every character plus its 1 px gap."""
        return sum(self.char_width(c, flags) + 1 for c in text)


class Screen:
    """One frame of a 128x64 screen. `strict` reports calls that fail on the
    radio (Lua 5.3 refuses a coordinate with a fraction)."""

    def __init__(self, fonts, problems):
        self.fonts = fonts
        self.problems = problems
        self.px = [[0] * LCD_W for _ in range(LCD_H)]
        self.texts = []        # every text drawn
        self.text_flags = {}   # text -> flags it was last drawn with
        self.text_boxes = []   # (text, x0, y0, x1, y1)
        self.last_right = self.last_left = self.next_pos = 0

    # -- helpers -----------------------------------------------------------
    def ints(self, what, *values):
        out = []
        for v in values:
            if v is None or isinstance(v, bool) or float(v) != int(v):
                self.problems.add(f"128x64: {what} got {v!r}: EdgeTX needs whole numbers")
                v = int(v or 0)
            out.append(int(v))
        return out

    def point(self, x, y, att):
        if 0 <= x < LCD_W and 0 <= y < LCD_H:
            if att & FORCE:
                self.px[y][x] = 1
            elif att & ERASE:
                self.px[y][x] = 0
            else:
                self.px[y][x] ^= 1

    def hline(self, x, y, w, pat, att):
        if y < 0 or y >= LCD_H or w == 0:
            return
        if w < 0:
            x, w = x + w + 1, -w
        if x + w <= 0 or x >= LCD_W:
            return
        if x < 0:
            w, x = w + x, 0
        w = min(w, LCD_W - x)
        for i in range(w):
            if pat & 1:
                self.point(x + i, y, att)
                pat = (pat >> 1) | 0x80
            else:
                pat >>= 1

    def vline(self, x, y, h, pat, att):
        if x < 0 or x >= LCD_W or h == 0:
            return
        if h < 0:
            y, h = y + h + 1, -h
        if y + h <= 0 or y >= LCD_H:
            return
        if y < 0:
            h, y = h + y, 0
        h = min(h, LCD_H - y)
        if pat == DOTTED and not y % 2:
            pat = ~pat & 0xFF
        for i in range(h):
            if pat & (1 << ((y + i) % 8)):
                self.point(x, y + i, att)

    def put_char(self, x, y, c, flags):
        """lcdDrawChar() + lcdPutPattern(). Returns the next x."""
        cols, height, flags = self.fonts.pattern(c, flags)
        inv = bool(flags & INVERS)
        small = (flags & 0x0700) == SMLSIZE
        next_pos = x - 1
        lines = len(cols[0])
        for i in range(len(cols) + 2):
            if not 0 <= x < LCD_W:
                x += 1
                next_pos += 1
                continue
            b = [0] * lines
            if i == 0:
                if x == 0 or not inv:
                    next_pos += 1
                    continue
                x -= 1
            elif i <= len(cols):
                b = cols[i - 1]
                if all(v == 0xFF for v in b):
                    if flags & FIXEDWIDTH:
                        b = [0] * lines
                    else:
                        continue
            for j in range(-1, height + 1):
                if j < 0 or (j == height and not small):
                    plot = False
                    if height >= 12 or (j < 0 and not inv) or y + j < 0:
                        continue
                else:
                    plot = bool(b[j // 8] & (1 << (j % 8))) if j // 8 < lines else False
                if inv:
                    plot = not plot
                self.point(x, y + j, FORCE if plot else ERASE)
            x += 1
            next_pos += 1
        return next_pos

    # -- the lcd.* functions -----------------------------------------------
    def clear(self, *_):
        self.px = [[0] * LCD_W for _ in range(LCD_H)]

    def refresh(self):
        pass

    def drawText(self, x, y, text, flags=0):
        x, y, flags = self.ints("lcd.drawText", x, y, flags or 0)
        text = str(text)
        size = flags & 0x0700
        orig_x = x
        width = self.fonts.text_width(text, flags)
        if flags & RIGHT:
            x -= width
        elif flags & CENTERED:
            x -= width // 2
        left = x
        for c in text:
            if (size == DBLSIZE or flags & BOLD) and c not in " _" and not (
                    "," <= c <= ":" or c.isalpha()):
                if size == DBLSIZE:
                    self.problems.add(f"128x64: {c!r} in {text!r} isn't in the DBLSIZE font")
            x = self.put_char(x, y, c, flags)
        height = {0: 7, SMLSIZE: 7, MIDSIZE: 12, DBLSIZE: 16}.get(size, 7)
        box = (left, y, left + max(width - 1, 0), y + height)
        if box[0] < 0 or box[2] > LCD_W or box[1] < 0 or box[3] > LCD_H:
            self.problems.add(f"128x64: text {text!r} goes off the screen {box}")
        if text.strip():
            for other, *b in self.text_boxes:
                if box[0] < b[2] and b[0] < box[2] and box[1] < b[3] and b[1] < box[3]:
                    self.problems.add(f"128x64: text {text!r} overlaps {other!r}")
            self.text_boxes.append((text, *box))
        self.texts.append(text)
        self.text_flags[text] = flags
        self.last_right = self.next_pos = x
        if size == MIDSIZE:
            self.last_right += 1
        if flags & RIGHT:
            self.last_right -= width
            self.next_pos -= width
            self.last_left = self.last_right
            self.last_right = orig_x
        else:
            self.last_left = orig_x

    def getLastPos(self):
        return self.last_right

    def getLastLeftPos(self):
        return self.last_left

    def drawPoint(self, x, y, flags=0):
        x, y, flags = self.ints("lcd.drawPoint", x, y, flags or 0)
        self.point(x, y, flags)

    def drawLine(self, x1, y1, x2, y2, pattern=None, flags=None):
        if pattern is None or flags is None:
            self.problems.add("128x64: lcd.drawLine needs a pattern and flags (error on the radio)")
            pattern, flags = pattern or SOLID, flags or 0
        x1, y1, x2, y2, pattern, flags = self.ints("lcd.drawLine", x1, y1, x2, y2, pattern, flags)
        if min(x1, y1, x2, y2) < 0 or x1 > LCD_W or x2 > LCD_W or y1 > LCD_H or y2 > LCD_H:
            self.problems.add(f"128x64: line ({x1},{y1})-({x2},{y2}) is off the screen: not drawn")
            return
        if pattern == SOLID and x1 == x2:
            self.vline(x1, min(y1, y2), abs(y2 - y1) + 1, SOLID, flags)
            return
        if pattern == SOLID and y1 == y2:
            self.hline(min(x1, x2), y1, abs(x2 - x1) + 1, SOLID, flags)
            return
        dx, dy = x2 - x1, y2 - y1
        sdx, sdy = (dx > 0) - (dx < 0), (dy > 0) - (dy < 0)
        dxabs, dyabs = abs(dx), abs(dy)
        x, y, px, py = dyabs >> 1, dxabs >> 1, x1, y1
        if dxabs >= dyabs:
            for _ in range(dxabs + 1):
                if (1 << (px % 8)) & pattern:
                    self.point(px, py, flags)
                y += dyabs
                if y >= dxabs:
                    y -= dxabs
                    py += sdy
                px += sdx
        else:
            for _ in range(dyabs + 1):
                if (1 << (py % 8)) & pattern:
                    self.point(px, py, flags)
                x += dxabs
                if x >= dyabs:
                    x -= dyabs
                    px += sdx
                py += sdy

    def check_rect(self, what, x, y, w, h):
        if w <= 0 or h <= 0:
            self.problems.add(f"128x64: {what} with size {w}x{h}")
        elif x < 0 or y < 0 or x + w > LCD_W or y + h > LCD_H:
            self.problems.add(f"128x64: {what} ({x},{y},{w},{h}) goes off the screen")

    def drawRectangle(self, x, y, w, h, flags=0, _t=None):
        x, y, w, h, flags = self.ints("lcd.drawRectangle", x, y, w, h, flags or 0)
        self.check_rect("rectangle", x, y, w, h)
        self.vline(x, y, h, SOLID, flags)
        self.vline(x + w - 1, y, h, SOLID, flags)
        if not flags & ROUND:
            x, w = x + 1, w - 2
        self.hline(x, y + h - 1, w, SOLID, flags)
        self.hline(x, y, w, SOLID, flags)

    def drawFilledRectangle(self, x, y, w, h, flags=0):
        x, y, w, h, flags = self.ints("lcd.drawFilledRectangle", x, y, w, h, flags or 0)
        self.check_rect("filled rectangle", x, y, w, h)
        for i in range(y, y + h):
            if flags & ROUND and i in (y, y + h - 1):
                self.hline(x + 1, i, w - 2, SOLID, flags)
            else:
                self.hline(x, i, w, SOLID, flags)

    def image(self, scale=4):
        img = Image.new("RGB", (LCD_W, LCD_H))
        on, off = (20, 24, 20), (182, 196, 170)  # like the radio's LCD
        img.putdata([on if v else off for row in self.px for v in row])
        return img.resize((LCD_W * scale, LCD_H * scale), Image.NEAREST)


LCD_FUNCTIONS = ["clear", "refresh", "drawText", "getLastPos", "getLastLeftPos", "drawPoint",
                 "drawLine", "drawRectangle", "drawFilledRectangle"]
