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
Lay the screen out in zones. Suggested arrangement (Claude may propose a better one).
Colours: sky blue for the aux bars, the stick dot and picker selections; green, amber and
red for status (no yellow, which was too harsh).
- **Status bar** (thin, along the top, on the MK3 and MK2): the
  date on the left (e.g. "Sat 7 Nov 2026"), the radio's battery on the right as an icon
  filled over the Radio Setup battery range plus the voltage, red at or below the radio's
  battery warning level. It stands in for EdgeTX's top bar, which App mode hides. No
  speaker volume: EdgeTX gives Lua no way to read it (no getter in `getGeneralSettings()` or
  anywhere else in `radio/src/lua/`).
- **Top right: VIDEO.** HDZero band/channel in very large text (e.g. "R3"), as set in the ELRS
  module's VTX Administrator, with its frequency in MHz beside the label and the power level
  (PWR; if VTX Admin leaves the power alone ("-"), the FC's). This is the only place the
  channel is shown. Once the FC has answered over MSP (see Q1):
  - Green when the FC has VTX Admin's channel (confirmed), amber when not, with the FC's side
    as the detail: "FC R5" (another channel), "PIT" (pit mode) or "NO VTX" (no VTX device).
  - With VTX Admin off: the FC's own channel and frequency (amber only for pit mode or no VTX).
  - Before the FC answers: white, or "--" and OFF when VTX Admin is off.
  Tap it (in fullscreen) to open the picker:
  - Bands R, F, E, B, A (ELRS's L isn't in Betaflight's default VTX table), channels 1–8,
    power -/1–8, then CANCEL or SEND. The heading shows the choice, e.g. "R3  5732MHz  PWR 2".
  - Until the FC's table is read, each power button has what that level does on an HDZero
    VTX underneath ("-" says "keep"). ELRS sends the level to Betaflight, which passes it to
    the VTX unchanged, and HDZero's firmware maps it (`parse_vtx_params` in hdzero-vtx's
    `src/msp_displayport.c`). Race/Whoop/Nano (default): 1 = 25mW, 2 = 200mW, 3 = 0mW,
    4–8 = 25mW. Freestyle V1/V2 (`Freestyle` option): 1 = 25mW, 2 = 200mW, 3 = 500mW,
    4 = 1W, 5 = 0mW, 6–8 = 25mW. A level past the VTX's own falls back to its minimum, so those
    labels are dimmed; the 0mW level (video off) is amber. Level 4 is labelled 1W in red in
    both tables (on a Race VTX it's really 25mW, but the user wants the reminder of what it
    does on a Freestyle VTX).
  - "POWER" sits level with the numbers and the table's name ("HDZ", or "HDZ FS") level with
    the labels, in the same small font. Where any label doesn't fit its button with "mW"
    (the MK2), they all drop it: "25", "200", "0", "1W".
  - EXIT, or leaving fullscreen, closes the picker without sending.
  - SEND sends straight away (no confirmation screen). It writes Band, Channel and Pwr Lvl
    to the module, presses "Send VTx", waits 0.3 s
    and reads them back. While that runs the channel shows grey; then green if the module holds
    the new values, red if not (or after 5 s without an answer), for 5 s.
  - Once the FC's VTX table has been read (linked), the picker follows it: the FC's band
    letters (ELRS sends a band number, the FC looks it up in its own table), only bands with
    a frequency, channels the table doesn't have greyed out and ignored, and the FC's power
    labels (e.g. "25", "200") instead of 1–8. The VIDEO panel uses the same letters,
    frequencies and power labels. Until then: Betaflight's default table.
- **Top left: ELRS.** Packet rate, TX power and telemetry ratio.
  Each value has a detail beside its label: the rest of the rate name plus the RF band
  ("Full", "2.4G", "Full 900M"), dynamic power ("Dyn" or its AUX switch), and the telemetry
  ratio or bandwidth ("1:64", "5859bps"). TX power from 1000mW is shown as "1W"/"2W" so all
  three values fit one font size. Telemetry Off shows yellow (the QUAD strip needs it).
  Until values arrive the panel says READING, or why there are none: NO MODULE (no CRSF
  module set up in the model), NO REPLY, or NOT ELRS. Values stay white while being re-read.
  Tap it (in fullscreen) to open the ELRS settings menu (with nothing to show, a tap reads
  the settings again):
  - One row per setting: RF BAND (ELRS 4.x with an LR1121, i.e. the MK3), RATE, POWER (max
    power), DYNAMIC and TELEM, each with < and > to step through the module's own options
    (skipping the empty ones it uses for values the hardware doesn't support). A changed
    value shows in blue. Then CANCEL or APPLY; EXIT or leaving fullscreen cancels.
  - A new RF band makes ELRS pick the packet rate itself, so the RATE row then shows "set by
    RF band" and isn't written.
  - APPLY writes only the changed settings (in row order), waits 0.3 s and reads them back.
    Each affected panel value then shows green if the module took it or red if not (ELRS can
    refuse, e.g. a rate change while a quad is connected), for 5 s. These settings are
    stored per model in the ELRS module.
- **Middle: STICKS and AUX**, laid out like the radio: left gimbal, aux grid, right gimbal,
  with an empty column (3% of the width) between each gimbal and the aux area.
  - **STICKS:** two gimbal circles, each with a dot showing the actual channel outputs,
    with the axis values (Y/T/R/P in %) underneath. The stick mode decides which gimbal
    shows which axes; channels come from the radio's default channel order.
  - **AUX:** 6 channels (CH5–CH10; CH1–CH4 are on the sticks), 2 columns of 3 rows with an
    empty gap between the columns: the channel's name as set on the radio's Outputs page, and
    a thin (about 5 px) live bar that fills from the centre, with a grey centre mark.
- **Status strip: QUAD.** Shows "NO LINK" until telemetry arrives (`getRSSI()` stays 0 until
  RQly streams). Then three cells, each with a big go/no-go value coloured green/yellow/red and
  a detail beside its label:
  - LINK: LQ (RQly). Green ≥80%, yellow ≥50%, red below. Detail: RSSI of the active antenna
    (EdgeTX reports ELRS's `ANT` as 1 or 2).
  - PACK: per-cell voltage. Green ≥4.00 V, yellow ≥3.75 V, red below, so a storage-charged or
    part-used pack stands out. Detail: cell count and total, e.g. "4S 16.6V". The cell count is
    worked out from the voltage when the link comes up (at most 4.40 V per cell) and kept while
    linked, so sag can't lower it; the next connection works it out again. The `Cells` option
    forces it. Below 2.5 V shows "NO PACK" (FC on USB power). Needs Betaflight's
    `report_cell_voltage` OFF (the default), so RxBt is the pack voltage.
  - FC: from the `FM` sensor. While disarmed Betaflight adds `*` (ready to arm), `!` (arming
    blocked) or `?` (GPS rescue not ready), shown as READY (green) or NO ARM / NO GPS (yellow).
    No suffix means armed: ARMED (red). `!FS!` shows !FS! / FAILSAFE (red). Detail: flight mode.
  - The VTX channel is in the VIDEO panel only, coloured by what the FC reports.

Touch and screen size:
- **Touch only works in fullscreen.** In App mode the widget fills the screen but gets no touch
  or key events until a long-press puts it into fullscreen. Long-press RTN leaves fullscreen.
  Lua can leave fullscreen (`lcd.exitFullScreen()`) but can't enter it. So everything must read
  correctly without fullscreen; touch is only for the VIDEO picker and the refresh tap. This
  also makes it pocket-safe.
- **MK2 (480x272):** the same layout as the MK3, named horizontal aux bars included. Zones
  under 400 px tall get a taller QUAD strip (0.24 of the height rather than 0.19) so its
  values stay large and bold, which makes the gimbals a little smaller. (An earlier compact
  layout put the named bars on a second page; dropped at the user's request.)
- **Menu button corner:** in App mode EdgeTX draws its menu button over the top-left corner
  (45 px square on the MK2, 62 px on the MK3) until the widget goes fullscreen, which a long
  press anywhere does. The layout doesn't avoid it. A widget can't start in fullscreen: the
  Lua API can only leave it (`lcd.exitFullScreen()`), and App mode keeps the button until then.

Widget options (max 5):
- `Light`: light background instead of black, for strong sun.
- `StickMode`: 0 = use the radio's stick mode (needs EdgeTX 2.12+, otherwise mode 2), 1–4 to force one.
- `Cells`: 0 = work out the quad's cell count from the voltage, 1–14 to force one.
- `Freestyle`: 0 = the VTX picker's power labels follow HDZero Race/Whoop/Nano VTXs, 1 = HDZero
  Freestyle V1/V2. A `BOOL`, since `CHOICE` options aren't in the 2.12 widget docs.

## Data sources
- Status bar: `getValue("tx-voltage")` (volts, 0.1 V steps) every 0.5 s; battery range and
  warning level from `getGeneralSettings()` (`battMin`, `battMax`, `battWarn`) and the date
  from `getDateTime()`, both every 10 s. The weekday is worked out from the date.
- Channel outputs: `getOutputValue()`. Aux labels come from `model.getOutput(i).name`, so they
  match the radio's Outputs page. Fall back to "CH5" etc. if the name is blank.
- Quad telemetry: CRSF sensors RQly, 1RSS/2RSS, ANT, RxBt (battery voltage), FM (flight mode).
  `Curr`, `Capa` and `Bat%` also exist. Look each one up once with `getFieldInfo()`; sensors
  only exist after telemetry first arrives, so missing ones are looked up again every 2 s.
  Read them with `getSourceValue()` (EdgeTX 2.11+) at most every 100 ms, and show "--" for a
  sensor that's missing or not current.
- ELRS settings (rate, power, telemetry ratio): read from the TX module using the CRSF parameter
  protocol (`crossfireTelemetryPush` / `crossfireTelemetryPop`, as the official ELRS Lua does).
  This must work **without** a quad connected. Find fields by name (Q2). Once linked, the
  RFMD/TPWR sensors can be used as a cross-check.
- VTX channel set: write the ELRS "VTX Administrator" band/channel parameters on the TX module,
  then trigger "Send VTx". Here is an example of an edgetx lua script that does this: https://github.com/Saqoosha/EasyVTXch
- VTX channel read-back: once linked, ask the FC with `MSP_VTX_CONFIG` over CRSF (Q1), then
  read its VTX table once per connection (`MSP_VTXTABLE_BAND` for bands 1–6, which are the
  ones ELRS can send, and `MSP_VTXTABLE_POWERLEVEL`). The setting is asked for again every
  10 s and 2.5 s after a send, never while armed. One request at a time, 3 s timeout, 3 tries.

## Behaviour
- Never block. CRSF parameter reads happen gradually across refresh/background calls.
  A visible widget only gets `refresh()` and a hidden one only `background()`, never both in
  the same cycle, so the CRSF/MSP state machine must be stepped from both.
- Cache the ELRS settings and show READING until they're loaded. A full scan pings for the
  module, then reads fields by ID, drops each field it doesn't need as soon as its name is in,
  and stops once it has the ones it needs; lost replies are retried twice. The known fields are
  re-read when the widget resumes after a tool, every 30 s while not armed, and in full scan
  on ENTER (in fullscreen).
- Don't break if no ELRS module is detected. Show a clear message instead.
- The VTX picker sends on SEND with no confirmation step (dropped at the user's request), and
  the module asks for none either. The choice still goes to **every quad that connects**,
  now and later, until it's changed (see Q1).
- Redraw rate: EdgeTX calls `refresh` once per UI cycle, every 50 ms (`MENU_TASK_PERIOD` in
  `radio/src/tasks.cpp`), so the sticks and bars update at most 20 times a second. Lua can't
  change that, and EdgeTX's own widgets update at the same rate.
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

What to show (as built: the VIDEO panel, see Layout):
- Before the FC answers (no link, telemetry off): VTX Admin's setting, in white.
- When the FC's setting matches VTX Admin: green. Only this state counts as confirmed.
- When it doesn't match: amber, with what the FC reports.

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
6. Quad: in the Betaflight CLI, check `vtxtable`. ELRS VTX Admin's own labels (in the ELRS Lua)
   assume the bands are in the order A, B, E, F, R (L optional). Once linked, the widget's picker
   uses the FC's own letters, so it sends the right row either way.
7. Optional: keep the ELRS Lua in `SCRIPTS/TOOLS/` to cross-check what the widget reads. If the
   Betaflight TX Lua's VTX page can read the quad, the MSP read-back will work too.

## TX12 version (128x64, black and white)
A separate script with its own code, because nothing of the widget carries over: the TX12 has
no widgets, no touch, no colour, a different `lcd` API and far less memory (the widget's
protocol modules alone need about 110 KB of Lua memory on a PC).
- **Files:** `SCRIPTS/TELEMETRY/PreRac.lua` (the screen EdgeTX loads) and `SCRIPTS/PRERACE/`
  (`link.lua` ELRS/FC, `view.lua` main screen, `menu.lua` both menus, loaded only while open).
- **Container:** a telemetry screen (Model > Display > Script). TELE on the main view shows
  it, PAGE keys switch telemetry screens, holding RTN leaves. Holding ENTER is EdgeTX's
  "reset telemetry" popup, so it isn't used.
- **Layout,** as on the MK3: date and radio battery; ELRS (rate, power, telemetry ratio,
  dynamic power) left and VIDEO (channel, frequency, HDZero power label) right; sticks and
  the six named aux bars; LINK / PACK / FC along the bottom.
- **No colour:** a warning is inverted, a bad value inverted and blinking. A tick beside the
  frequency means the FC reports VTX Admin's channel; otherwise "FCR5", "PIT" or "NOVTX".
- **Controls:** scroll moves the bar under VIDEO or ELRS, ENTER opens that menu. In a menu,
  scroll moves between rows, ENTER edits a row (scroll changes it, ENTER keeps it and jumps
  to the button), RTN cancels. The VTX menu opens already editing the channel, so a channel
  change is ENTER, scroll, ENTER, ENTER. Nothing is sent before SEND / APPLY.
- **Left out** to save memory: the FC's VTX table (bands and power labels are ELRS's own, which
  match HDZero's), the Freestyle power table, light theme, stick values as numbers.
- **Firmware:** written for Lua 5.2 and 5.3 and only long-standing API calls, so it should run
  on an original TX12 (EdgeTX 2.10 or older) as well as a TX12 MK2. Not yet run on a radio;
  memory use there is unmeasured (about 52 KB on a 64-bit PC, roughly half expected on the
  radio; SYS > Statistics > Debug shows free memory).
- **Preview:** `python3 utils/preview_tx12.py` (`utils/bwlcd.py` is the 128x64 LCD and fonts,
  ported from the EdgeTX source).

## Build order
1. Static layout, plus live sticks and aux bars with output names. *(Done: `WIDGETS/PreRace/`.
   The MK2 uses the same layout; see "Touch and screen size".)*
2. Quad telemetry status strip. *(Done: `telem.lua`.)*
3. Reading ELRS settings over CRSF. *(Done: `crsf.lua`, `elrs.lua`.)*
4. VTX channel picker and send. *(Done: `vtx.lua`, `picker.lua`.)*
5. VTX read-back from the FC over MSP. *(Done: `msp.lua`, FC part of `vtx.lua`.)*

Steps 1–2 can be tested in Companion. Steps 3–5 need the real radio (and a quad for 5): in
Companion no module answers CRSF reads.
