# Prompt: build "Halo" for Windows

Copy everything below the line into Claude Code on the Windows PC. If you can, also copy this whole
`Halo` folder to the PC (e.g. `C:\Users\<you>\Projects\Halo-mac`) — the prompt tells Claude to read
the Mac source as the reference implementation.

---

I want you to build **Halo**, a Windows tray app that drives my AKKLED monitor backlight strip (a USB
LED strip behind my monitor) so I don't need the vendor app. I already have a working macOS version
written in Swift; this is a port of it. Everything you need about the hardware is below — it was
reverse-engineered and verified on the real device, so trust these details over guesses.

If a folder called `Halo-mac` (or a copy of the Mac project with `Sources/Halo/*.swift`) exists on
this PC, read it first: `Protocol.swift`, `RobobloqDevice.swift`, `SyncEngine.swift`,
`AudioAnalyzer.swift`, `LightController.swift`, `SpeakerCalibrator.swift`. Port the behaviour and
the numbers from there; the spec below summarises them.

Work in phases and check with me on the real strip after each phase (I'll tell you what I see).
Don't move on until the current phase works.

## Tech stack (use this unless you find a hard blocker)

- **C# / .NET 8**, WinForms or WPF, single tray app (`NotifyIcon`) with a small popup menu window and
  a Settings window. Publish as a single self-contained `.exe`.
- **USB HID:** `HidSharp` (NuGet).
- **Screen capture:** DXGI Desktop Duplication (via `Vortice.Direct3D11` / `Vortice.DXGI`) or
  `Windows.Graphics.Capture`. Capture the chosen monitor, downscale to ~90 px tall on the GPU or
  by sampling, BGRA.
- **System audio:** WASAPI loopback capture of the default render device with `NAudio`
  (`WasapiLoopbackCapture`). FFT: write a small radix-2 FFT or use `NAudio.Dsp.FastFourierTransform`.
- **Mic (for speaker-delay measurement):** NAudio `WasapiCapture` + `WasapiOut`.
- Settings stored as JSON in `%APPDATA%\Halo\settings.json`, loaded by merging over defaults so new
  fields get default values.

## The hardware

- Controller: **Robobloq** USB HID, sold as AKKLED. **VID 0x1A86, PID 0xFE07**, usage page
  **0xFF00** (pick that interface if several show up).
- All traffic is **64-byte output reports, report ID 0**.
  **Windows gotcha:** HID writes on Windows need the report ID as the first byte, so each write is
  **65 bytes: `0x00` + the 64-byte report.** Input reports also arrive with the leading `0x00`.
- My strip: **78 LEDs**, layout **left 18 / top 42 / right 18 / bottom 0**, LED 1 at the
  **bottom-left**, running up the left side, across the top, down the right side (seen from the
  front). Make layout and start corner (bottom-left / bottom-right) configurable, and auto-split
  the LED count by the monitor's aspect: `side = round(count / (2 + aspect))`, `top = count − 2·side`.
- The vendor app must not be running at the same time (it fights over the device).

## Wire protocol

Checksum = sum of all preceding bytes, `& 0xFF`. A packet index byte starts at **2** on connect and
increments (wrapping) on every packet sent, short or long.

**Short packet ("RB")** — used for every command except per-LED frames:
```
52 42 <len = body.length + 5> <index> <body...> <checksum>   then zero-pad to 64 bytes
```

**Long packet ("SC")** — used for per-LED frames (command 0x80):
```
53 43 <len hi> <len lo> <index> <command> <payload...> <checksum>
len = payload.length + 7 (16-bit big-endian). Zero-pad the whole thing to a multiple of 64 and
send it as consecutive 64-byte reports.
```

**Command bodies** (the `body` of a short packet):

| Purpose | Body |
|---|---|
| Unstick / don't-open-website | `93 00` |
| Device info request | `82` |
| Solid color | `86 01 R G B n (n+1) 00 00 00 FE`  (n = LED count, max 254; the second range is a dummy the vendor app also sends) |
| Brightness | `87 v` where v = round(percent/100·255), **minimum 1** (0 is read as max) |
| Built-in effect | `85 02 i`, i = 0..6: Rainbow, Breathing, Twist, Beat, Twirl, Lemon, Electric |
| Effect speed | `8A (100 − speed)`, speed 0 (slow)…100 (fast) |
| Mic "pickup" effect | `85 03 07` (Circles — the only code that works; 0x00–0x0D and 0x10–0x13 do nothing) |
| Turn off | `97` |

**Per-LED frame:** long packet, command `0x80`, payload = a list of ranges, each 5 bytes:
`start R G B end` (1-based, inclusive LED indices). Encode the LED colors like this:
1. Merge adjacent LEDs with identical colors into runs.
2. While there are more runs than `maxRanges` (default 78, configurable down to 34 like the vendor
   app), merge the adjacent pair with the smallest added squared error:
   `cost = na·nb/(na+nb) · |meanA − meanB|²` (mean RGB per run, n = LEDs in run). The merged run's
   color is the mean.
3. Emit each run as `start, round(meanR), round(meanG), round(meanB), end`.

**Device info reply** (input report, after stripping the Windows report-ID byte): starts `52 42`,
byte[4] = `0x82`. Bytes [5..7] id, [8] screen size in inches, **[11] LED count**, [12..19] uuid,
**[21],[22],[23] firmware** (`a.b.c`). When the LED count differs from the layout total, re-run the
auto layout.

**Critical gotcha — controller stalls:** sometimes the controller stops accepting frames and
the strip freezes on an old color. Sending `93 00` resets its parser. So send `93 00` **on connect,
at the start of every apply, and every 3 seconds while streaming frames.**

On connect: send `93 00`, then `82`, then apply the current mode. Handle unplug/replug (poll for the
device every couple of seconds or use device-change notifications).

Writes go through one dedicated writer thread. Frames use a **latest-frame slot**: if a new frame
arrives before the previous one was written, drop the old one (never queue up stale frames).
Only send a frame if some LED changed by more than 1 in any channel, or 1 s has passed.

## Modes

1. **Screen** — sync to a chosen monitor (I have a 34" LG UltraWide 3440×1440 as a second display;
   default to the largest/ultrawide one, but let me pick).
2. **Music** — react to whatever the PC is playing (WASAPI loopback). Styles: Spectrum, Pulse,
   Party, Screen.
3. **Auto** — Screen sync while a fullscreen window (video, game) covers the chosen monitor;
   otherwise a calm solid **ambient color**. Check once a second: the foreground window's rect
   equals the monitor's bounds (±2 px), and it isn't the desktop/shell/our own window.
4. **Color** — one solid color (color picker + a few presets).
5. **Effect** — the 7 built-in effects + speed slider.
6. **Pickup** — controller-mic Circles (low priority; I barely use it).

Global: on/off, brightness 1–100.

## Screen sync (port exactly)

- Capture the monitor at ~90 px height (width by aspect), **30 fps** (configurable).
- Each LED samples a zone along the edge: left side bottom→top, top left→right, right side
  top→bottom, bottom right→left; mirror horizontally if the strip starts bottom-right. Zone depth =
  **12%** of width/height into the picture. Zones are equal slices of each edge.
- Per zone: average RGB → temporal smoothing `current = current·a + target·(1−a)` with
  **a = smoothing (default 0.5)** → grade:
  - saturation boost around luma: `luma = 0.2126r + 0.7152g + 0.0722b`,
    `c' = luma + (c − luma)·1.25`
  - gamma: `out = (c'/255)^1.5 · 255`, values < 2 → 0
- Then white balance (per-channel multipliers, clamped). My tuned values for my wall:
  **R 0.99, G 0.78, B 0.53**. Settings has sliders for these plus a "white preview" button that
  shows pure white on the strip while adjusting.
- **Black-bar detection** (letterbox/pillarbox; default on):
  - Threshold: a pixel is "lit" if max(R,G,B) > **12**.
  - Only scan the middle of the frame: rows from 15% to 78% of the height when testing columns,
    columns from 10% to 90% of the width when testing rows (player titles/controls draw over bars).
    Sample every 2nd pixel.
  - Only edge regions can be bars: up to 30% of the width per side, 25% of the height top/bottom.
  - Keep a per-column and per-row counter of consecutive dark frames; any lit pixel resets it to 0.
  - An edge column/row counts as bar when it has been dark for `max(10, fps)` frames (~1 s).
  - Bars come in equal pairs, so use the **narrower** side: `side = min(left, right)`,
    `cap = min(top, bottom)`. Only accept if side ≥ 3% of width and the wider side didn't hit the
    30% limit (that means a dark scene, not bars); same for top/bottom with 3%/25%.
  - The zones are then laid out inside the detected picture area.

## Music mode (port exactly)

**Analyzer** (mono mix of the loopback stream, 48 kHz typical):
- 24 log-spaced bands from 40 Hz to min(14 kHz, Nyquist − 100). FFT size **1024**, Hann window,
  ring buffer of the last 1024 samples, analysed on every audio buffer.
- `range = 18 + sensitivity·0.3` dB.
- Loudness: RMS in dB vs a slowly falling peak (`peak = max(db, peak − 0.04, −60)`);
  value = clamp((db − (peak − range)) / range); silent (rms < 1e-4) → 0.
- Bands: mean magnitude per band in dB; per-band peak
  `peak[b] = max(db, peak[b] − 0.05, globalPeak − 30)`; level = clamp((db − (peak[b] − range))/range).
- Smoothing of loudness and bands: rising `old + (new−old)·0.7`, falling `old·0.82 + new·0.18`.
- **Beat detection in the time domain** (low latency, don't wait for the FFT):
  two cascaded one-pole low-passes at 150 Hz (`a = 1 − exp(−2π·150/sr)`), 256-sample blocks,
  block energy e = RMS of the filtered signal. `bassPeak = max(e, bassPeak·0.9995)`.
  Beat when `e > 0.002 && e > bassSlow·(1.9 − sensitivity·0.008) && e > bassPeak·0.3 && e > prevE`
  and ≥ 150 ms since the last beat. Then `bassSlow = bassSlow·0.985 + e·0.015`.
  On a beat: `beat = 1`, `beatCount++`, and **render a frame immediately** (don't wait for the timer).
  `beat` decays ×0.86 per output frame.

**Palettes** (gradient stops, bass → treble): Rainbow (FF0000, FF8C00, FFFF00, 00FF3C, 00C8FF,
2800FF, B400FF), Fire (FF0000, FF4600, FF9600, FFE650), Ocean (0014FF, 0078FF, 00DCFF, 00FFAA),
Neon (FF0096, AA00FF, 3C28FF, 00E6FF), Sunset (7800FF, FF008C, FF3C28, FFAA00), Forest (00FF1E,
78FF00, 00FF96, 00B4FF), Ice (FFFFFF, 96DCFF, 2878FF), Custom (two colors I pick). Sample with
linear interpolation between stops.

**Styles:**
- **Spectrum** (my favourite): LED i at position p = i/(n−1) shows band level at p (interpolated
  over the 24 bands) raised to the power 1.4, times the palette color. The palette moves along the
  strip ("Color motion"):
  - `offset` eases toward `target`: `offset += (target − offset)·0.22` per frame.
  - **Beat (default):** target += 0.0008 per frame, plus **+0.12 on every beat and +0.3 on every
    4th beat**. → colors keep changing with the music, gliding over ~0.3 s, not smooth-only and
    not as aggressive as Party. (I tested this and it feels right.)
  - Flow: target += 0.0015 per frame. Off: target = 0.
  - Color position uses a mirrored wrap so it never jumps:
    `y = ((p + offset)/2) mod 1`, `t = 1 − |1 − 2y|`, color = palette(t).
  - Keep the numbers small: when both exceed 4, subtract 2 from both.
- **Pulse:** whole strip breathes. `hue += 0.0008`/frame; `t = hue + (beatCount mod 8)/8`;
  brightness `v = 0.06 + 0.94·max(beat, loudness·0.75)`; LED i uses
  `x = (t + i/n·0.15) mod 1`, color = palette(1 − |1 − 2x|)·v.
- **Party** (club style): each beat = hard hit in a new color; palette index steps by the golden
  ratio (`k·0.381966 mod 1`; with 2 stops just alternate). Background glow `0.04 + 0.18·loudness`.
  Pattern changes every 16 beats, cycling: full flash / left-right halves alternating per beat /
  4 segments chasing around the strip / burst ring expanding from the top centre. Optional
  **strobe**: on every 4th beat when loudness > 0.7, 2 frames of full white.
- **Screen:** screen-sync colors scaled by `0.2 + 0.8·max(beat, loudness)`.

**Anti-flicker fade** applied per LED per channel after the style:
`s = smoothness/100`; attack `0.9 − 0.6s` (Party: 1), release `0.4 − 0.34s`
(Party: `0.55 − 0.35s`); values < 2 → 0.

**Sensitivity & smoothness per style**, each with a "Use recommended" button:
Spectrum 50/70, Pulse 55/60, Party 65/35, Screen 50/60.

## Audio ↔ light delay (important — I use Bluetooth speakers/headphones)

Bluetooth plays sound late (mine measured **352 ms** while the OS reported only 123 ms), so the
lights must be **delayed** to line up with what I hear:

`lightDelay = max(0, speakerLatency − captureLatency − 8 ms + fineTune)`

- `captureLatency`: how late loopback audio reaches us (estimate from buffer timestamps vs now;
  WASAPI loopback is usually ~10–30 ms).
- `speakerLatency`: the **measured** value for the current output device (stored per device name),
  falling back to what Windows reports (`IAudioClient.GetStreamLatency` + device period) if never
  measured.
- `fineTune`: a slider, −150…+150 ms.
- Apply the delay by holding each rendered frame back that long before sending it.
- Re-check the default output device when it changes and pick up its stored measurement.
- **"Measure speaker delay"** button: request mic access, open the built-in mic, play **8 beeps**
  (20 ms, 2 kHz) spaced 0.75 s apart through the current output device, record them, find each
  beep with a matched filter (cross-correlate the recording with the beep; accept a peak if it's
  > 10× the median), take the delay between scheduled play time and detected time for each, use the
  **median**, and only accept if the spread is < 20 ms (otherwise tell me to retry in a quieter room).
  Use separate capture and playback streams (on the Mac, one combined engine failed with Bluetooth).
  Show the result per device in the UI.
- Toggle "Auto speaker sync" (default on).

## Automation (replacement for Apple Shortcuts)

Register a `halo://` URL protocol under `HKCU\Software\Classes\halo` that launches `Halo.exe "%1"`;
make the app single-instance and forward the URL to the running instance (named pipe or mutex +
`WM_COPYDATA`). Support:
`halo://on`, `off`, `toggle`, `mode/<screen|music|auto|color|effect|pickup>`, `color/<hex>`,
`ambient/<hex>`, `brightness/<1-100|up|down>`, `effect/<name|index>`, `pickup/circles`,
`music/<spectrum|pulse|party|screen>`, `sensitivity/<0-100>`, `smoothness/<0-100>`,
`motion/<off|flow|beat>`, `palette/<name>`, `speed/<0-100>`, `display/<name part|main>`,
`blackbars/<on|off>`, `settings`, `calibrate`. Also accept the same as command-line args so I can
bind them in Stream Deck / AutoHotkey / Task Scheduler. List them in the Settings window.

## Other behaviour

- Tray icon menu: on/off, a 3×2 mode grid, brightness, and the controls for the current mode
  (display picker + black-bar toggle for Screen; style, palette, color motion, strobe, sliders,
  delay info + measure button for Music; ambient color for Auto; etc.). Clicking the tray icon
  opens it; "Settings…" opens the full window.
- Settings window: Lights, Strip layout (counts per side, start corner, auto, a **test pattern**
  button that lights left = red, top = green, right = blue so I can confirm direction), Screen sync
  (fps, smoothing, saturation, gamma, sampling depth, max ranges, black bars), White balance
  (with white preview), Automation URL list, General (start with Windows via
  `HKCU\...\Run`, turn off when the PC sleeps, turn off on quit), Device (connected?, LED count,
  firmware).
- Sleep/wake: lights off on sleep / lock if enabled, restore on resume
  (`SystemEvents.PowerModeChanged`, `SessionSwitch`).
- On quit: synchronously send `97` + black solid before exiting if "turn off on quit" is on.
- Low CPU: capture small, reuse buffers, no allocations per frame in hot loops where avoidable.

## Phases

1. Find the device, print device info (LED count, firmware), send solid red / green / blue,
   brightness, off. I confirm on the strip.
2. Per-LED frames + test pattern (confirm direction and that the range encoding works).
3. Screen sync from my ultrawide, then black-bar detection, then white balance.
4. Music mode: analyzer, Spectrum (with Beat color motion), Pulse, Party, Screen; palettes;
   recommended tunings.
5. Speaker-delay measurement + auto delay.
6. Auto mode, effects, pickup, `halo://` automation, tray/settings polish, start with Windows,
   sleep handling, single-file publish.

Put the project in a git repo with a README covering the protocol, build steps and the URL list.
