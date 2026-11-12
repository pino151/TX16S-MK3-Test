#!/usr/bin/env python3
"""Preview the TX12's Pre-race telemetry screen (128x64, black and white).

Runs SCRIPTS/TELEMETRY/PreRac.lua against a mock of EdgeTX's Lua API for
black-and-white radios and saves what it draws to preview/ as PNGs, drawn
with the radio's own bitmap fonts (utils/bwlcd.py), 4x enlarged.

Everything runs twice: on Lua 5.2 (EdgeTX up to 2.10) and on Lua 5.3
(EdgeTX 2.11 and later), since a TX12 may have either. The same fake ELRS
modules and flight controller as utils/preview.py answer over CRSF.

Reports problems that are easy to miss on the radio: drawing off the screen,
text over other text, coordinates that aren't whole numbers (an error on
Lua 5.3), globals the script creates, and behaviour checks (reading the ELRS
settings, the telemetry states, sending a VTX channel and applying ELRS
settings with the scroll wheel and ENTER).

A layout and logic check, not a simulator: memory use in particular can only
be measured on the radio.

Usage:
  pip install lupa pillow
  python3 utils/preview_tx12.py

The first run downloads the fonts from the EdgeTX GitHub repo into
utils/.fonts (or point --fonts at radio/src/fonts/std in an EdgeTX checkout).
Exits with status 1 if any problem was found.
"""

import argparse
import sys
from pathlib import Path

import lupa.lua52
import lupa.lua53

import bwlcd
import fake_elrs
import preview

REPO = preview.REPO
SCRIPT = "/SCRIPTS/TELEMETRY/PreRac.lua"
NEXT, PREV = bwlcd.CONSTANTS["EVT_VIRTUAL_NEXT"], bwlcd.CONSTANTS["EVT_VIRTUAL_PREV"]
ENTER, EXIT = bwlcd.CONSTANTS["EVT_VIRTUAL_ENTER"], bwlcd.CONSTANTS["EVT_VIRTUAL_EXIT"]


class Radio(preview.Radio):
    """preview.Radio with a black-and-white radio's Lua API."""

    def __init__(self, lua, problems):
        super().__init__(lua, problems)
        g = lua.globals()
        for name in list(preview.CONSTANTS) + list(preview.COLORS):
            g[name] = None  # no colour constants, VCENTER etc. on these radios
        for name, value in bwlcd.CONSTANTS.items():
            g[name] = value
        lcd = {n: (lambda n: lambda *a: getattr(self.screen, n)(*a))(n)
               for n in bwlcd.LCD_FUNCTIONS}
        lcd["getLastRightPos"] = lcd["getLastPos"]
        g.lcd = lua.table_from(lcd)

    def get_value(self, src):
        """Telemetry sensors read 0 while nothing is streaming (EdgeTX's
        luaGetValueAndPush), by name or by the id getFieldInfo gave."""
        if src == "tx-voltage":
            return self.tx_voltage
        name = src if isinstance(src, str) else next(
            (n for n, i in preview.SENSOR_IDS.items() if i == int(src)), None)
        if name in preview.SENSOR_IDS:
            return (self.telemetry or {}).get(name, 0) if self.telemetry else 0
        self.problems.add(f"getValue({src!r}): not mocked, check the script")
        return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default="preview", help="output folder for the PNGs")
    ap.add_argument("--scale", type=int, default=4, help="enlarge the PNGs")
    ap.add_argument("--fonts", help="folder with EdgeTX's font_*.png files")
    args = ap.parse_args()

    problems = set()
    fonts = bwlcd.Fonts(args.fonts, preview.FONT_CACHE)
    out = REPO / args.out
    out.mkdir(exist_ok=True)
    sizes = {}
    for label, runtime in (("Lua 5.2", lupa.lua52), ("Lua 5.3", lupa.lua53)):
        found = set()
        try:
            check(runtime.LuaRuntime(unpack_returned_tuples=True), fonts, found,
                  out if label == "Lua 5.3" else None, args.scale, sizes)
        except (lupa.lua52.LuaError, lupa.lua53.LuaError) as e:
            found.add(f"Lua error: {e}")
        problems |= {f"{label}: {p}" for p in found}

    if sizes:
        print("Lua memory on this PC (64-bit, unstripped; the radio needs roughly half):")
        for what, kb in sizes.items():
            print(f"  {what}: {kb:.1f} KB")
    if problems:
        print(f"\n{len(problems)} problem(s):")
        for p in sorted(problems):
            print("  -", p)
        return 1
    print("\nno problems found")
    return 0


def check(lua, fonts, problems, out, scale, sizes):
    g = lua.globals()
    for path in sorted((REPO / "SCRIPTS").rglob("*.lua")):
        result = g.loadfile(path.as_posix())
        if isinstance(result, tuple) and result[0] is None:
            problems.add(f"syntax: {result[1]}")
    radio = Radio(lua, problems)
    lua.execute(preview.LUA_SETUP)(REPO.as_posix(), lambda msg: problems.add(str(msg)))
    step = 5  # ticks per frame: EdgeTX runs scripts about every 50 ms
    memory = lua.eval('function() collectgarbage() collectgarbage() '
                      'local kb = collectgarbage("count") return kb end')
    state = {}

    def start(module=None, fc=None):
        """A freshly loaded script on a radio with this module and quad."""
        radio.names = dict(preview.NAMES)
        radio.discovered, radio.last, radio.telemetry = set(), {}, None
        radio.set_module(module)
        radio.fc = fc
        radio.tx_voltage = 7.9
        state["script"] = None
        base = memory()
        script = g.loadScript(SCRIPT)
        script = (script[0] if isinstance(script, tuple) else script)()
        script.init()
        state["script"], state["base"] = script, base
        return script

    def run(frames=2, event=0, outputs=None, telemetry="same"):
        """`frames` cycles: background(), then run() as on a visible screen.
        The first run() gets `event`."""
        if outputs is not None:
            radio.outputs = outputs
        if telemetry != "same":
            radio.set_telemetry(telemetry)
        for i in range(frames):
            radio.clock += step
            state["script"].background()
            radio.screen = bwlcd.Screen(fonts, problems)
            state["script"].run(event if i == 0 else 0)
        return radio.screen

    def keys(*events, frames=2):
        for e in events:
            screen = run(frames, e)
        return screen

    def expect(screen, text, what):
        if text not in screen.texts:
            problems.add(f"{what}: no {text!r} on screen (has {screen.texts})")

    def flags(screen, text, want, what):
        if (screen.text_flags.get(text, 0) & (bwlcd.INVERS | bwlcd.BLINK)) != want:
            problems.add(f"{what}: {text!r} drawn with flags {screen.text_flags.get(text)}")

    def save(screen, label):
        if out:
            screen.image(scale).save(out / f"PreRac-128x64-{label}.png")
            print(f"wrote {args_out(out)}/PreRac-128x64-{label}.png")

    def args_out(path):
        return path.relative_to(REPO) if path.is_relative_to(REPO) else path

    radio.outputs = preview.OUT_IDLE

    # -- no module, a silent one, one that isn't ELRS ----------------------
    for module, text in ((None, "NO MODULE"), (fake_elrs.mk3_internal(silent=True), "NO REPLY"),
                         (fake_elrs.mk3_internal(serial=b"TBS\0"), "NOT ELRS")):
        start(module)
        s = run(100)
        expect(s, text, "ELRS panel message")
        expect(s, "NO LINK", "no telemetry")
        if s.texts.count("--") != 1:
            problems.add(f"{text}: VIDEO should show '--' with no settings")
        keys(ENTER, NEXT, ENTER)
        if "[ SEND ]" in radio.screen.texts or "[ APPLY ]" in radio.screen.texts:
            problems.add(f"{text}: a menu opened without settings")
    save(run(), "nomodule")

    for name, make, rate, power, tlm, dyn, video in (
            ("elrs4", fake_elrs.mk3_internal, "500Hz", "250mW", "TLM 1:64", "Dyn", "R3"),
            ("elrs3", fake_elrs.mk2_ranger_micro, "250Hz", "100mW", "TLM 1:16", "", "--")):
        module = make()
        band = "Band/Enable" if any(f["name"] == "Band/Enable" for f in module.fields) else "Band"

        # -- reading the settings, with a lost reply on the way ------------
        rate_id = module.id_of("Packet Rate")
        module.drop = {(rate_id, 0), (rate_id, 1)}
        start(module)
        s = run(160, outputs=preview.OUT_IDLE)
        for text in (rate, power, tlm, video, "Sat 7 Nov", "7.9V", "NO LINK"):
            expect(s, text, f"{name} idle")
        if dyn:
            expect(s, dyn, f"{name} dynamic power")
        for text in preview.NAMES.values():
            expect(s, text, f"{name} output names")
        save(s, f"{name}-idle")
        sizes.setdefault("main screen", memory() - state["base"])

        # Nothing more is read once the settings are in (until the re-read).
        reads = len(module.reads)
        run(100)
        if len(module.reads) != reads:
            problems.add(f"{name}: the module is still being read after the scan")
        # ...and the re-read every 30 s picks up a change made elsewhere.
        module.set("Max Power", 1)
        s = run(620)
        expect(s, "25mW", f"{name} re-read after 30 s")
        module.set("Max Power", 4 if name == "elrs4" else 3)

        # -- radio battery warning, blank output names ---------------------
        start(make())
        radio.tx_voltage = 6.5
        radio.names = {}
        s = run(160)
        flags(s, "6.5V", bwlcd.INVERS, f"{name} low radio battery")
        expect(s, "CH5", f"{name} unnamed output")
        radio.tx_voltage = 7.9

        # -- telemetry: linked, warnings, armed ----------------------------
        module, fc = make(), fake_elrs.FakeFc(band=5, ch=3)
        start(module, fc)
        s = run(200, outputs=preview.OUT_MOVING, telemetry=dict(preview.TLM_GOOD))
        for text in ("100%", "4S 4.15V", "READY"):
            expect(s, text, f"{name} linked")
            flags(s, text, 0, f"{name} linked")
        save(s, f"{name}-linked")
        if name == "elrs4":
            # The FC is on VTX Admin's channel: frequency with a tick.
            expect(s, "5732", "FC on the same channel")
            if not (s.px[13][104] and s.px[10][106]):
                problems.add("no tick beside the frequency though the FC confirmed the channel")
        else:
            expect(s, "R1" if False else "R3", "VTX Admin off: the FC's channel")
            expect(s, "OFF", "VTX Admin off")
        s = run(12, telemetry=dict(preview.TLM_POOR))
        expect(s, "62%", f"{name} poor link")
        flags(s, "62%", bwlcd.INVERS, f"{name} LQ warning")
        flags(s, "4S 5.58V", 0, f"{name} cell count kept from the first reading")
        flags(s, "NO ARM", bwlcd.INVERS, f"{name} arming blocked")
        s = run(12, telemetry=dict(preview.TLM_POOR, RQly=40, RxBt=14.4, FM="!FS!"))
        flags(s, "40%", bwlcd.INVERS | bwlcd.BLINK, f"{name} LQ bad")
        flags(s, "4S 3.60V", bwlcd.INVERS | bwlcd.BLINK, f"{name} pack low")
        flags(s, "FAILSAFE", bwlcd.INVERS | bwlcd.BLINK, f"{name} failsafe")
        save(s, f"{name}-warnings")
        s = run(12, telemetry=dict(preview.TLM_GOOD, RxBt=0.1, FM="AIR"))
        expect(s, "NO PACK", f"{name} FC on USB")
        expect(s, "ARMED", f"{name} armed")
        # Armed: nothing is asked of the module or the FC.
        reads, asked = len(module.reads), len(fc.requests)
        run(700)
        if len(module.reads) != reads or len(fc.requests) != asked:
            problems.add(f"{name}: the module or FC was polled while armed")
        s = run(12, telemetry=None)
        expect(s, "NO LINK", f"{name} link lost")

        # -- the FC on another channel, in pit mode, without a VTX ---------
        if name == "elrs4":
            for change, text in ((("ch", 5), "FCR5"), (("pit", 1), "PIT"), (("vtx_type", 0), "NOVTX")):
                module, fc = make(), fake_elrs.FakeFc(band=5, ch=3)
                start(module, fc)
                run(200, telemetry=dict(preview.TLM_GOOD))
                setattr(fc, *change)
                s = run(220)
                expect(s, text, f"FC {change[0]} differs from VTX Admin")
                flags(s, text, bwlcd.INVERS, f"FC {change[0]}")

        # -- VTX menu: cancel, then pick a channel and send ----------------
        module, fc = make(), fake_elrs.FakeFc(band=5, ch=3)
        start(module, fc)
        run(200, telemetry=dict(preview.TLM_GOOD))
        s = keys(ENTER)
        expect(s, "[ SEND ]", f"{name} VTX menu opens on ENTER")
        s = keys(NEXT)
        ch = 4 if name == "elrs4" else 2
        expect(s, f"VTX  R{ch}  {5769 if ch == 4 else 5695}MHz", f"{name} VTX menu title")
        save(s, f"{name}-vtx")
        sizes.setdefault("with a menu open", memory() - state["base"])
        keys(EXIT)                     # cancels the edit: back to the old channel
        s = keys(EXIT)                 # closes the menu
        if module.writes or "[ SEND ]" in s.texts:
            problems.add(f"{name}: RTN in the VTX menu didn't cancel ({module.writes})")
        sizes.setdefault("after closing the menu", memory() - state["base"])
        # ENTER opens on the channel, scroll changes it, ENTER keeps it and
        # jumps to SEND, ENTER sends.
        keys(ENTER, NEXT, ENTER)
        s = keys(ENTER, frames=120)
        pwr = module.value("Pwr Lvl")
        want = [(band, 5), ("Channel", ch), ("Pwr Lvl", pwr), ("Send VTx", 1)]
        if module.writes != want:
            problems.add(f"{name}: VTX send wrote {module.writes}, expected {want}")
        expect(s, f"R{ch}", f"{name} new channel after the send")
        if (fc.band, fc.ch) != (5, ch):
            problems.add(f"{name}: the FC didn't get R{ch} (has {fc.band}, {fc.ch})")
        # Band and power: scroll back from SEND to the rows.
        module.writes.clear()
        keys(ENTER, ENTER)             # open, keep the channel: on SEND
        keys(PREV, ENTER, NEXT, NEXT, ENTER)  # power row: two levels up
        keys(PREV, PREV, PREV, ENTER, PREV, ENTER)  # band row: R -> F
        s = keys(ENTER, frames=120)
        want = [(band, 4), ("Channel", ch), ("Pwr Lvl", pwr + 2), ("Send VTx", 1)]
        if module.writes != want:
            problems.add(f"{name}: band/power send wrote {module.writes}, expected {want}")
        expect(s, f"F{ch}", f"{name} new band after the send")

        # -- ELRS menu: change the power and apply -------------------------
        module = make()
        start(module)
        run(160)
        s = keys(NEXT, ENTER)
        expect(s, "ELRS SETTINGS", f"{name} ELRS menu opens")
        expect(s, "[ APPLY ]", f"{name} ELRS menu")
        save(s, f"{name}-elrs")
        row = 2 if name == "elrs4" else 1  # scrolls down to the Power row
        old = module.value("Max Power")
        keys(*[NEXT] * row, ENTER, NEXT, ENTER)
        s = keys(ENTER, frames=120)
        if module.writes != [("Max Power", old + 1)]:
            problems.add(f"{name}: ELRS apply wrote {module.writes}")
        expect(s, "500mW" if name == "elrs4" else "250mW", f"{name} new power after APPLY")
        # Rates of the other band are blank on ELRS 4.x: scrolling skips them,
        # and a changed RF band takes the rate out of the menu.
        if name == "elrs4":
            module.writes.clear()
            keys(ENTER)  # the ELRS panel still has the focus
            s = keys(NEXT, ENTER, PREV)
            expect(s, "333Hz Full", "previous rate, blank ones skipped")
            keys(EXIT)
            s = keys(PREV, ENTER, NEXT, ENTER)
            expect(s, "set by band", "rate row after an RF band change")
            keys(ENTER, frames=60)
            if module.writes != [("RF Band", 2)]:
                problems.add(f"RF band apply wrote {module.writes}")

    writes = [str(k) for k in g.GLOBAL_WRITES.values()]
    if writes:
        problems.add(f"the script creates globals: {sorted(set(writes))}")


if __name__ == "__main__":
    sys.exit(main())
