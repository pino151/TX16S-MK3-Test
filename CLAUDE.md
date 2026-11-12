# EdgeTX scripts for RadioMaster TX16S MK3

## The radios
- RadioMaster TX16S MK3, running EdgeTX 2.12 or newer. EdgeTX added the MK3 in 2.12.0, and
  3.0 isn't released yet (Nov 2026), so check Radio Settings → Version rather than assuming.
- STM32H7 processor, with internal flash plus a microSD card
- 5" color IPS touchscreen, 800x480. That's larger than the original TX16S (480x272).
- Has a built-in gyro/motion sensor and an internal dual-band ExpressLRS module (LR1121, 2.4GHz + 900MHz)
- Second radio: TX16S MK2 (480x272 touchscreen) with an external RadioMaster Ranger Micro
  ELRS module (2.4GHz). The color widget runs on both.
- Third radio: RadioMaster TX12 (128x64 black-and-white LCD, no touch; scroll wheel, ENTER, RTN).
  It has no widgets, so it gets its own telemetry-screen script with its own code (see below).
  EdgeTX 2.11+ only releases firmware for the TX12 MK2; an original TX12 is on 2.10 or older.
- Fourth radio: RadioMaster Pocket. To EdgeTX it is the same as the TX12: 128x64 1-bit LCD, the
  same keys (scroll wheel, ENTER, RTN, PAGE, TELE, SYS, MDL), STM32F407, internal ELRS. It runs
  the TX12 script unchanged; only the glass is physically smaller.

## Rules for Lua scripts
- The runtime is EdgeTX Lua: **Lua 5.3 from EdgeTX 2.11** (32-bit integers and floats, with
  `bit32` kept), Lua 5.2 before that. There's no `io` beyond EdgeTX's
  `io.open/read/write/close`, no `os.execute` and no `require` of C modules.
- On 5.3, `/` always gives a float: `1000 / 1000 .. "W"` is "1.0W", and a drawing function
  given a coordinate with a fraction is an error. Use `math.floor` and `string.format`.
- TX12 scripts must run on 5.2 and 5.3: no `//`, no `&` `|` `<<` operators.
- Never hard-code screen sizes. Use `LCD_W` / `LCD_H`, and for widgets use the `zone` dimensions,
  so scripts work at 800x480 (MK3), 480x272 (MK2) and in any widget zone size.
- Use the color API (`lcd.RGB`, `COLOR_THEME_*` flags) and support touch events where it makes sense.
- Keep memory use low. Create tables and bitmaps once in `init`/`create`, not every frame.
- Never block. `run`/`refresh` must return quickly, so use `getTime()` for timing instead of loops.
- Keep each script small. Put shared helpers in a separate file and load it with `loadScript()`.
- Check the EdgeTX Lua reference (https://luadoc.edgetx.org, source at
  https://github.com/EdgeTX/lua-reference-guide) before using any API function.
  Don't guess function names or signatures. Where the docs are vague, check the EdgeTX source
  (`radio/src/lua/` in https://github.com/EdgeTX/edgetx).

## Script types and where they go on the SD card
| Folder | Type | Notes |
|---|---|---|
| `SCRIPTS/TOOLS/` | Tool | Runs from SYS > Tools. Return `{ init=..., run=... }` |
| `SCRIPTS/MIXES/` | Mixer | Runs every cycle. Keep it tiny; filename max 6 chars |
| `SCRIPTS/FUNCTIONS/` | Function | Triggered by Special Functions |
| `SCRIPTS/TELEMETRY/` | Telemetry screen | Black-and-white radios only. Return `{ init, background, run }`; filename max 6 chars. Chosen in Model > Display |
| `SCRIPTS/PRERACE/` | (helpers) | Code for `SCRIPTS/TELEMETRY/PreRac.lua`, loaded with `loadScript()` |
| `WIDGETS/<Name>/main.lua` | Widget | For the color screen. Return `{ name, options, create, update, refresh, background }`. Folder name max 8 chars; `name` max 10 chars |

The repo mirrors the SD card layout, so these folders can be copied straight to the card.
Each radio type has its own code: the color radios (MK3, MK2) use `WIDGETS/PreRace/`, the TX12
uses `SCRIPTS/TELEMETRY/PreRac.lua` plus `SCRIPTS/PRERACE/`. Nothing is shared between the two.

## Black-and-white radios (TX12)
- 128x64, 1 bit. `lcd` has no colors, no `sizeText`, no circles; drawing is XOR unless given
  `FORCE` or `ERASE`; `lcd.drawLine` needs all six arguments.
- Memory is tight (tens of KB for all Lua). Load menus only while they're open, keep option
  lists as strings, and don't cache what a call can fetch.

## Testing
0. For color-screen widgets, run `python3 utils/preview.py` first (needs `pip install lupa pillow`). It runs the
   widget's Lua against a mock of the EdgeTX API, writes PNGs at 800x480 and 480x272 to `preview/`, and reports
   problems such as drawing outside the zone or creating globals. It also simulates CRSF telemetry and an ELRS TX
   module (`utils/fake_elrs.py`) and runs behaviour checks. It's a layout and logic check, not a simulator.
   For the TX12 script run `python3 utils/preview_tx12.py`: the same idea at 128x64 with the radio's
   bitmap fonts, on Lua 5.2 and 5.3, driven by scroll/ENTER/RTN key events.
1. Run it in the EdgeTX Companion simulator, using a TX16S MK3 profile on the same firmware version as the radio.
   Anything that talks to the ELRS module over CRSF can't be tested there (no module answers), so test that on the radio.
2. Then copy it to the radio. Connect USB, choose "USB Storage (SD)", and copy the `SCRIPTS/` and `WIDGETS/` folders.
3. When a script errors, check the error message shown on the radio and the Companion debug output.

## Repo conventions
- `utils/` holds PC-side helpers (Python), such as a script that syncs the repo to the SD card.
- Commit working changes with clear messages. This repo is used from two computers, so always pull before starting work.
