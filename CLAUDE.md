# EdgeTX scripts for RadioMaster TX16S MK3

## The radio
- RadioMaster TX16S MK3, running EdgeTX 3.0 or newer (the MK3 requires 3.0+)
- STM32H7 processor, with internal flash plus a microSD card
- 5" color IPS touchscreen, 800x480. That's larger than the original TX16S (480x272).
- Has a built-in gyro/motion sensor and an internal dual-band ExpressLRS module (2.4GHz + 900MHz)

## Rules for Lua scripts
- The runtime is EdgeTX Lua (Lua 5.2 with EdgeTX extensions). There's no `io` beyond EdgeTX's
  `io.open/read/write/close`, no `os.execute` and no `require` of C modules.
- Never hard-code screen sizes. Use `LCD_W` / `LCD_H`, and for widgets use the `zone` dimensions,
  so scripts work at 800x480 and in any widget zone size.
- Use the color API (`lcd.RGB`, `COLOR_THEME_*` flags) and support touch events where it makes sense.
- Keep memory use low. Create tables and bitmaps once in `init`/`create`, not every frame.
- Never block. `run`/`refresh` must return quickly, so use `getTime()` for timing instead of loops.
- Keep each script small. Put shared helpers in a separate file and load it with `loadScript()`.
- Check the EdgeTX 3.x Lua reference (https://luadoc.edgetx.org) before using any API function.
  Don't guess function names or signatures.

## Script types and where they go on the SD card
| Folder | Type | Notes |
|---|---|---|
| `SCRIPTS/TOOLS/` | Tool | Runs from SYS > Tools. Return `{ init=..., run=... }` |
| `SCRIPTS/MIXES/` | Mixer | Runs every cycle. Keep it tiny; filename max 6 chars |
| `SCRIPTS/FUNCTIONS/` | Function | Triggered by Special Functions |
| `WIDGETS/<Name>/main.lua` | Widget | For the color screen. Return `{ name, options, create, update, refresh, background }`. Name max 10 chars |

The repo mirrors the SD card layout, so these folders can be copied straight to the card.

## Testing
1. Run it in the EdgeTX Companion simulator, using a TX16S MK3 profile on the same firmware version as the radio.
2. Then copy it to the radio. Connect USB, choose "USB Storage (SD)", and copy the `SCRIPTS/` and `WIDGETS/` folders.
3. When a script errors, check the error message shown on the radio and the Companion debug output.

## Repo conventions
- `utils/` holds PC-side helpers (Python), such as a script that syncs the repo to the SD card.
- Commit working changes with clear messages. This repo is used from two computers, so always pull before starting work.
