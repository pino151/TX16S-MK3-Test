# Pre-race check dashboard: widget spec

## Purpose
A full-screen dashboard (App mode) on a TX16S MK3, used while walking to the launch stand.
It should also run on my TX16S MK2 (see "Radios and firmware").
At a glance it should display
1. The video channel/pwr, which can be changed if needed.
2. ELRS packet rate, TX power and telemetry ratio.
3. Sticks and aux switches outputs
4. With the quad plugged in: link, battery, arming status and VTX channel all look good.

Not for my mid-flight use, but might be looked at by spotter. Readability matters more than density: big text and high contrast,
because it's used outdoors in sunlight.

## Radios and firmware
- **TX16S MK3** (primary): 800x480, internal ELRS module (LR1121, dual band 2.4GHz + 900MHz).
- **TX16S MK2**: 480x272, external RadioMaster Ranger Micro (ELRS, 2.4GHz only). The MK2's
  internal RF must be off or set to something other than CRSF: if both modules are CRSF,
  `crossfireTelemetryPush` sends to the internal one.
- **EdgeTX 2.12 or newer** on both. App mode needs 2.11+, and the MK3 is supported from 2.12.0.
  EdgeTX 3.0 isn't released yet (Nov 2026); the script should also run on it.
- **ELRS TX firmware 3.x or 4.x.** Parameter names differ between them (see Q2 below).

## Container: a widget in App mode
Decided after research (see "Research findings"). One widget, placed on a main view that uses
the **App mode** layout (`Layout1x1AM`, EdgeTX 2.11+). App mode removes the top bar, trims and
sliders, so the widget gets the whole screen as its zone. Not a tool script: a tool pauses all
other Lua while it's open, and needs a trip to SYS > Tools every time.

## Layout (800x480, touch)
Lay the screen out in zones. Suggested arrangement (Claude may propose a better one):
- **Top left: VIDEO.** HDZero band/channel in very large text (e.g. "R3"). Tap it to open a picker
  (bands: R, F, E, etc.; channels 1–8), then send the choice via ELRS VTX Admin. When linked,
  grey out channels the FC's vtxtable marks as unsupported (frequency 0, see Q1).
- **Top right: ELRS.** Packet rate, TX power and telemetry ratio. Display only, no editing.
- **Center: STICKS.** Two gimbal circles with live crosshairs showing the actual
  channel outputs.
- **Center: AUX.** Just below sticks display. 11 channels, two columns of 5, and one last one centered below: the channel's name as set on the radio's
  Outputs page, and a live bar/position indicator.
- **Status strip: QUAD.** Shows "NO LINK" until telemetry arrives, then:
  - Link: LQ (RQly) with green/yellow/red and RSSI
  - Pack: per-cell voltage, with cell count auto-detected and the total voltage
  - FC: Betaflight flight mode / arming flags (`FM` sensor)
  - VTX: the band/channel/frequency the FC reports over MSP (see Q1)

Touch and screen size:
- **Touch only works in fullscreen.** In App mode the widget fills the screen but gets no touch
  or key events until a long-press puts it into fullscreen. Long-press RTN leaves fullscreen.
  Lua can leave fullscreen (`lcd.exitFullScreen()`) but can't enter it. So everything must read
  correctly without fullscreen; touch is only for the VIDEO picker and the refresh tap. This
  also makes it pocket-safe.
- **MK2 (480x272):** the full layout won't fit at sunlight-readable sizes. Use a compact
  arrangement computed from `zone.w` / `zone.h` (for example aux bars on a second page) rather
  than shrinking text.

## Data sources
- Channel outputs: `getOutputValue()`. Aux labels come from `model.getOutput(i).name`, so they
  match the radio's Outputs page. Fall back to "CH5" etc. if the name is blank.
- Quad telemetry: CRSF sensors RQly, 1RSS/2RSS, ANT, RxBt (battery voltage), FM (flight mode).
  `Curr`, `Capa` and `Bat%` also exist. Look each one up once with `getFieldInfo()`. Show "--"
  if a sensor is missing.
- ELRS settings (rate, power, telemetry ratio): read from the TX module using the CRSF parameter
  protocol (`crossfireTelemetryPush` / `crossfireTelemetryPop`, as the official ELRS Lua does).
  This must work **without** a quad connected. Find fields by name (Q2). Once linked, the
  RFMD/TPWR sensors can be used as a cross-check.
- VTX channel set: write the ELRS "VTX Administrator" band/channel parameters on the TX module,
  then trigger "Send VTx". Here is an example of an edgetx lua script that does this: https://github.com/Saqoosha/EasyVTXch
- VTX channel read-back: ask the FC with `MSP_VTX_CONFIG` over CRSF once linked (Q1).

## Behaviour
- Never block. CRSF parameter reads happen gradually across refresh/background calls.
  A visible widget only gets `refresh()` and a hidden one only `background()`, never both in
  the same cycle, so the CRSF/MSP state machine must be stepped from both.
- Cache the ELRS settings and show "reading…" until they're loaded. Allow a manual refresh tap.
- Don't break if no ELRS module is detected. Show a clear message instead.
- The VTX picker needs a confirmation step before sending. The module itself asks for no
  confirmation, so ours is the only one. The confirm text should say that the choice is sent
  to **every quad that connects** (see Q1).
- The widget receives a copy of **every** incoming CRSF frame, including replies meant for other
  scripts. Filter by frame type, source address and field ID.
- Opening any tool (including the ELRS Lua) freezes the widget completely. On return, notice the
  `getTime()` gap, discard queued frames and re-read the ELRS settings, since they may have
  changed.
- Every widget on the SD card is loaded when the model loads. Keep `main.lua` small and load the
  CRSF, MSP and picker code with `loadScript()`.
- Widget folder name max 8 characters; the `name` field max 10.

## Research findings (answered 2026-11-07)
Checked against EdgeTX source (main = 3.0.0 in development, plus the 2.11 and 2.12 branches),
the EdgeTX Lua reference source, ExpressLRS 3.x and 4.x maintenance branches, Betaflight master,
the Betaflight TX Lua scripts and EasyVTXch. Sources are listed at the end of this section.

### Q1. Can the widget learn the VTX channel the quad is actually on?
**Not from telemetry, but yes by asking the FC over MSP.**

- Betaflight's CRSF telemetry sends no VTX frame, and EdgeTX doesn't decode one.
- ELRS "Send VTx" gets no confirmation back. The TX sends `MSP_SET_VTX_CONFIG` to the FC 3 times,
  500 ms apart, then `MSP_EEPROM_WRITE`. Its internal "confirmed" state only means the link was
  up while it sent.
- **MSP over CRSF works**, and is what the Betaflight TX Lua scripts use:
  - Request: `crossfireTelemetryPush(0x7A, {0xC8, 0xEA, 0x30 + seq, 0x00, 88, 88})`, i.e. to the FC
    (`0xC8`) from the radio (`0xEA`), MSP v1 status byte (`0x20` version + `0x10` start + 4-bit
    sequence), size 0, command 88 (`MSP_VTX_CONFIG`), XOR checksum.
  - Reply: frame type `0x7B` with `data[1] == 0xEA`, `data[2] == 0xC8`, possibly over several
    frames. Parse it like `mspReceivedReply()` in the Betaflight TX Lua `MSP/common.lua`.
  - `MSP_VTX_CONFIG` reply bytes: vtx type (0 unsupported, 1 RTC6705, 3 SmartAudio, 4 Tramp,
    5 MSP = HDZero, 255 unknown), band (1-based into the FC's vtxtable), channel (1–8), power
    index, pit mode, frequency (2 bytes, little-endian, MHz), device ready, low-power-disarm,
    pit-mode frequency (2 bytes), vtxtable available, band count, channel count, power-level count.
  - `MSP_VTXTABLE_BAND` (137) with payload `{band}` returns the band's name, letter and each
    channel's frequency (0 = channel not supported). The Betaflight Lua sends this one as `0x7C`
    because it carries a payload.

Caveats:
- This is the FC's setting, which the HDZero follows. It isn't a reading of the VTX's RF output,
  but it's the best available.
- Asking can itself mark the FC's MSP VTX as ready (Betaflight `vtx_msp.c`), so trust "device
  ready" only on the first reply.
- Needs a link and a Telem Ratio other than Off.
- **Band order matters.** ELRS sends `(band − 1) × 8 + (channel − 1)` with ELRS bands numbered
  A=1, B=2, E=3, F=4, R=5, L=6. Betaflight looks that number up in its own vtxtable. If the FC's
  vtxtable bands are in a different order, ELRS silently sets the wrong band. The widget can
  check this with `MSP_VTXTABLE_BAND` (e.g. FC band 5's letter must be `R`).
- ELRS VTX band/channel are stored **once for the whole TX module, not per model** (packet rate,
  power and telemetry ratio are per model). While Band isn't Off, ELRS **re-sends it every time
  any quad connects**.

What to show:
- After sending: "sent R3".
- When the MSP reply matches: "FC R3 · 5732 MHz ✓". Only this state may be called confirmed.
- When it doesn't match: a clear warning with what the FC reports.
- No MSP reply (no link, telemetry off): stay on "sent R3".

### Q2. ELRS parameter names, 3.x vs 4.x
Field IDs are assigned when the module boots and differ between firmware versions and hardware,
so always match by name. Field IDs run from 1 to the field count in the device info reply.

| Setting | ELRS 3.x | ELRS 4.x | Notes |
|---|---|---|---|
| RF band | (none) | `RF Band` | New in 4.x, only on LR1121 modules (the MK3). It comes before Packet Rate, so every field ID after it shifts. |
| Packet rate | `Packet Rate` | same | Text selection. Option text depends on hardware (LR1121 vs the Ranger Micro's SX1280). Show the option text; never map index numbers, the firmware reverses them internally. |
| Telemetry ratio | `Telem Ratio` | same | `Std;Off;1:128;1:64;1:32;1:16;1:8;1:4;1:2;Race`, plus a unit such as ` (1:64)` or ` (xxxxbps)`. |
| TX power | folder named e.g. `TX Power (100 Dynamic)`, children `Max Power` and `Dynamic` | same | The folder name includes the current setting, so match the prefix `TX Power`. |
| VTX folder | `VTX Administrator`, or e.g. `VTX Admin (R:3:1)` once a band is set | same | Match the prefix `VTX Admin`. |
| VTX band | `Band`: `Off;A;B;E;F;R;L` | `Band/Enable`: `Disabled;A;B;E;F;R;L` | Index numbers unchanged (A=1 … L=6). |
| VTX channel | `Channel` (UINT8, min 1, max 8) | same | Write the channel number 1–8. |
| VTX power, pit | `Pwr Lvl` (`-;1;…;8`), `Pitmode` | same | 4.x marks Channel, Pwr Lvl and Pitmode hidden while the band is disabled. |
| Send | `Send VTx` (command) | same | Writing status 1 sends straight away. |

Protocol (same in 3.x and 4.x):
- Ping: push `0x28` `{0x00, 0xEA}`. Reply `0x29`: destination, source (`0xEE` = TX module), name
  (null-terminated), serial (4 bytes, `ELRS` = `0x454C5253`), hardware version (4), software
  version (4), field count (1), parameter version (1). No reply means no CRSF module: show a message.
- Read: push `0x2C` `{0xEE, 0xEA, fieldId, chunk}`. Reply `0x2B`: destination, source, field ID,
  chunks remaining, then the payload (join the chunks): parent ID, type (bit 7 = hidden),
  name (null-terminated), then by type:
  - text selection (9): options separated by `;` (null-terminated), value, min, max, default,
    unit (null-terminated). Keep empty options when splitting: they are placeholders for rates
    the hardware doesn't support.
  - UINT8 (0): value, min, max, default, unit.
  - folder (11): the name is the current (dynamic) name, followed by the child field IDs.
  - command (13): status, timeout, info text.
- Write: push `0x2D` `{0xEE, 0xEA, fieldId, value}`.
- Don't skip fields that have the hidden bit set: they still carry values.
- Send from `0xEA`, as the current ELRS Lua does (the 3.x Lua used `0xEF`; both are accepted).
- Like EasyVTXch, cache the found field IDs on the SD card together with the field count, and
  re-check names after loading the cache.

### Q3. Can a widget use `crossfireTelemetryPush` in EdgeTX? Widget in App mode or tool?
**Yes, and a widget in App mode is the right container.**

- Widgets get the same Lua functions as tool scripts, with no check on script type
  (`radio/src/lua/widgets.cpp`, `api_general.cpp`).
- On color radios each widget and tool gets its own copy of every incoming CRSF frame (2.11,
  2.12 and main, `radio/src/telemetry/telemetry.cpp`). The widget can't steal the ELRS Lua's
  replies, and the ELRS Lua can't steal the widget's.
- App mode is in 2.11, 2.12 and main (`radio/src/gui/colorlcd/layouts/layout1x1AppMode.cpp`).
- Limits are listed under "Layout" (touch only in fullscreen) and "Behaviour"
  (refresh/background, freeze while a tool runs, memory).
- A tool script or a tool with a widget front end isn't needed. A tool would pause the widget,
  mixer and function scripts while open, and has to be opened each time.

### Sources
- EdgeTX: https://github.com/EdgeTX/edgetx (`radio/src/lua/api_general.cpp`, `lua_widget.cpp`,
  `widgets.cpp`, `api_colorlcd_lvgl.cpp`, `radio/src/gui/colorlcd/standalone_lua.cpp`,
  `mainview/widget.cpp`, `layouts/layout1x1AppMode.cpp`, `radio/src/telemetry/telemetry.cpp`,
  `crossfire.cpp`, `sensor_names.h`)
- EdgeTX Lua reference source (what luadoc.edgetx.org is built from):
  https://github.com/EdgeTX/lua-reference-guide
- ExpressLRS: https://github.com/ExpressLRS/ExpressLRS (3.x `src/lib/LUA/tx_devLUA.cpp`,
  `src/lua/elrsV3.lua`; 4.x `src/lib/tx-crsf/TXModuleParameters.cpp`, `src/lua/elrs.lua`;
  both `src/lib/VTX/devVTX.cpp`)
- Betaflight: https://github.com/betaflight/betaflight (`src/main/msp/msp.c`,
  `src/main/io/vtx_msp.c`, `src/main/telemetry/crsf.c`)
- Betaflight TX Lua scripts: https://github.com/betaflight/betaflight-tx-lua-scripts
  (`src/SCRIPTS/BF/MSP/crsf.lua`, `MSP/common.lua`, `PAGES/vtx.lua`, `vtx_tables.lua`)
- EasyVTXch: https://github.com/Saqoosha/EasyVTXch (`ARCHITECTURE.md`)

## Test setup (MK3)
1. Radio Settings → Version: EdgeTX 2.12.0 or newer. Use the same version in Companion.
2. Note the ELRS TX firmware version (shown in the ELRS Lua), since 3.x and 4.x names differ.
3. Test model: internal RF on (CRSF/ELRS), external RF off.
4. Add a main view with the **App mode** layout; the widget goes in its single zone.
5. Telem Ratio not Off (`Std` is fine), needed for the MSP read-back.
6. Quad: in the Betaflight CLI, `vtxtable` bands should be in the order A, B, E, F, R (L optional),
   or ELRS VTX Admin will set the wrong band.
7. Optional: keep the ELRS Lua in `SCRIPTS/TOOLS/` to cross-check what the widget reads. If the
   Betaflight TX Lua's VTX page can read the quad, the MSP read-back will work too.

## Build order
1. Static layout, plus live sticks and aux bars with output names.
2. Quad telemetry status strip.
3. Reading ELRS settings over CRSF.
4. VTX channel picker and send.
5. VTX read-back from the FC over MSP.

Steps 1–2 can be tested in Companion. Steps 3–5 need the real radio (and a quad for 5): in
Companion no module answers CRSF reads.
