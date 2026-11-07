# Pre-race check dashboard: widget spec

## Purpose
A full-screen dashboard (App mode) on a TX16S MK3, used while walking to the launch stand.
At a glance it should display
1. The video channel/pwr, which can be changed if needed.
2. ELRS packet rate, TX power and telemetry ratio.
3. Sticks and aux switches outputs
4. With the quad plugged in: link, battery, arming status and VTX channel all look good.

Not for my mid-flight use, but might be looked at by spotter. Readability matters more than density: big text and high contrast,
because it's used outdoors in sunlight.

## Layout (800x480, touch)
Lay the screen out in zones. Suggested arrangement (Claude may propose a better one):
- **Top left: VIDEO.** HDZero band/channel in very large text (e.g. "R3"). Tap it to open a picker
  (bands: R, F, E, etc.; channels 1–8), then send the choice via ELRS VTX Admin.
- **Top right: ELRS.** Packet rate, TX power and telemetry ratio. Display only, no editing.
- **Center: STICKS.** Two gimbal circles with live crosshairs showing the actual
  channel outputs.
- **Center: AUX.** Just below sticks display. 11 channels, two columns of 5, and one last one centered below: the channel's name as set on the radio's
  Outputs page, and a live bar/position indicator.
- **Status strip: QUAD.** Shows "NO LINK" until telemetry arrives, then:
  - Link: LQ (RQly) with green/yellow/red and RSSI
  - Pack: per-cell voltage, with cell count auto-detected and the total voltage
  - FC: Betaflight flight mode / arming flags (FMode sensor)
  - VTX: the channel the quad reports, if obtainable (see open questions)

## Data sources
- Channel outputs: `getOutputValue()`. Aux labels come from `model.getOutput(i).name`, so they
  match the radio's Outputs page. Fall back to "CH5" etc. if the name is blank.
- Quad telemetry: CRSF sensors RQly, 1RSS/2RSS, ANT, RxBt (or Bat), FMode. Look each one up once
  with `getFieldInfo()`. Show "--" if a sensor is missing.
- ELRS settings (rate, power, telemetry ratio): read from the TX module using the CRSF parameter
  protocol (`crossfireTelemetryPush` / `crossfireTelemetryPop`, as the official ELRS Lua does).
  This must work **without** a quad connected. Once linked, the RFMD/TPWR sensors can be used as
  a cross-check.
- VTX channel set: write the ELRS "VTX Administrator" band/channel parameters on the TX module,
  then trigger "Send VTx". Here is an example of an edgetx lua script that does this: https://github.com/Saqoosha/EasyVTXch

## Behaviour
- Never block. CRSF parameter reads happen gradually across refresh/background calls.
- Cache the ELRS settings and show "reading…" until they're loaded. Allow a manual refresh tap.
- Don't break if no ELRS module is detected. Show a clear message instead.
- The VTX picker needs a confirmation step before sending.

## Open questions to research before coding
1. Can the widget learn the VTX channel the quad is actually on? Betaflight's CRSF telemetry may
   not report it. If it can't, show "sent: R3" rather than "confirmed".
2. What are the exact ELRS 3.x/4.x parameter names and indexes for packet rate, TX power,
   telemetry ratio and VTX Admin? Read them by name, not by fixed index, because they vary
   between firmware versions.
3. Can a widget (as opposed to a tool script) use `crossfireTelemetryPush` in EdgeTX 3.x? Is App
   mode the right container, or does this need a tool script with a widget front end?

## Build order
1. Static layout, plus live sticks and aux bars with output names.
2. Quad telemetry status strip.
3. Reading ELRS settings over CRSF.
4. VTX channel picker and send.
