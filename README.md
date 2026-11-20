# Halo

A small macOS menu-bar app for the AKKLED monitor backlight strip. It replaces the vendor app and needs no activation or internet connection.

| Mode | What it does |
|---|---|
| **Screen** | Mirrors the edges of the chosen display at about 30 fps. Black bars (letterbox/pillarbox) are skipped, so the side LEDs keep showing the picture: an edge column counts as a bar once it has stayed pure black (≤12) for about a second in the middle of the frame, which ignores player titles and controls. Bars are taken as equal pairs at the narrower side's width, and only realistic sizes count (3–30 % per side, 3–25 % top/bottom). Verified with a synthetic 16:9-on-21:9 test: bars read 26 columns against 27.5 expected, and held through dark edges and dark scenes. Diagnostics: `defaults read local.halo.backlight debug.blackBars`. |
| **Music** | Follows the Mac's audio: pick a preset (*Chill*, *Groove*, *Party*, *Club*), see [Music](#music) |
| **Auto** | A fullscreen window on the chosen display (video, game) → screen sync; otherwise another app playing sound → Music; otherwise a warm ambient color |
| **Color** | One solid color |
| **Effect** | The controller's 7 built-in animations, with speed control |

Also included: per-display selection, white balance with a live white preview, brightness, launch at login, lights off on sleep or quit, and a layout test pattern. Opening Halo again from Finder or Spotlight opens its settings window.

## Music

Pick a preset; everything else lives under *Advanced* and *Speaker sync*. A preset sets how the lights react (style, motion, accents, tuning); palette, strobe and speaker sync stay as you set them. Changing anything under Advanced shows the preset as **Custom**, so no setting can quietly change how a preset looks.

| Preset | Look |
|---|---|
| **Chill** | Spectrum, colors drift slowly. No flashes. |
| **Groove** | Spectrum following the bass: colors jump on kicks, snares flash the top, hi-hats shimmer on the treble side. |
| **Party** | Party patterns at intensity 50: colors crossfade on the beat, the strip never goes dark. |
| **Club** | The original Party: hard hits, a new color every kick, a new pattern every phrase (+ snare flashes). |

### Styles and options (Advanced)

- **Spectrum**: bass on LED 1 (bottom-left) through treble at the last LED. *Color motion*:
  - **Flow**: slow drift.
  - **Beat**: every kick lifts the whole strip at once, a hard one blooming further over ~2 frames. The palette flows while bass plays and jumps on each kick by how hard it hits (against the loudest kicks of the last ~20 s), with a bigger jump every 4th beat.
  - **Wave**: Beat, but each kick's colors start at the bass end and travel across in ~0.6 s.
- **Party**: a new color per kick and a new pattern each 16-beat phrase of the tempo grid, or at once when the song moves to a new section. *Intensity* runs from 100 (the original: hard cuts, optional strobe) down to soft (crossfades, never dark).
- **Screen**: screen colors, brightness follows the music.
- **Snare/clap accents**: the top middle flashes toward white for ~0.1 s, without changing colors, so kick ("boom") and snare ("tak") read as different hits.
- **Hi-hat shimmer**: three LEDs at the treble end sparkle faintly on each hat.
- **Follow song energy** (Spectrum): beat effects ×0.55 in verses and breakdowns, ×1.45 in choruses and drops.
- **Follow stereo**: the side away from the louder channel dims (up to 85 % at 12 dB).
- Palettes: Rainbow, Fire, Ocean, Neon, Sunset, Forest, Ice, or a custom two-color gradient. Each style keeps its own sensitivity and smoothness. Smoothness only softens small wobbles and fades; a rise as big as a kick lands in the same frame.

The settings window shows the tempo and which part of the song is playing.

### How the music is read

Everything is analysed straight from the samples in ~5 ms steps:

- **Kick**: below ~150 Hz, level over one ~21 ms bass cycle so it doesn't swing with the wave's phase. A kick must rise sharply over the last ~40 ms and beat the fading peak of the previous kick, so a long or wobbling 808 note counts once. A snare that bumps the bass band at the same moment, with the bass well short of a real kick, counts as the snare.
- **Snare/clap**: a sharp hit in 1–4.5 kHz at least as strong as the band above 6 kHz (rejecting hi-hats), loud next to the song's kicks (> −22 dB), and not followed by a kick within 30 ms (a kick's beater click reaches that band first).
- **Hi-hat**: a sharp rise above 6 kHz that's stronger there than in the snare band.
- **Tempo**: the beat period (70–180 BPM) that best explains the gaps between kicks over the last ~12 s; a gap k beats long counts 1/k, so kicks on 1 and 3 still give the beat.
- **Song energy**: the last ~3 s of loudness and bass against the biggest part heard so far (forgetting 3 dB a minute). Until the song has gone clearly bigger than it started, or for its first minute, it reads at most 0.7, so a first verse isn't taken for the chorus. Two seconds of silence start a new song: range and tempo are learned afresh. A large, lasting change in energy marks a new section.

**Timing.** Lights are held back to match the speaker: `speaker latency − time for audio to reach Halo − USB write time (measured)`, plus *Fine-tune*. Each kick and snare frame is scheduled from when the hit started in the audio, not when it was detected, so detection lag (a few ms for kicks, 30 ms for snares) doesn't make lights late. Speaker latency is macOS's figure or a microphone measurement (*Measure speaker delay*: 8 beeps found in the built-in mic's recording with a matched filter). Bluetooth speakers often play later than macOS reports: a Logi Z407 measured 352 ms against 123 ms reported. What the strip's controller adds can't be measured from the Mac, so *Sync test* plays a kick every 0.6 s and flashes the strip white through the same capture → detection → delay path; move Fine-tune until flash and kick land together.

**Tests.** `./test.sh` runs the detector tests on synthetic audio: 808 notes, loud/soft and fast kicks, kick strength, snares and claps under quiet and loud hats, hats alone, snare bodies vs. kicks, hi-hat counts, stereo balance, kick/snare onset times (within 8/12 ms), tempo (four-on-the-floor, kicks on 1 and 3, missing kicks), 16-beat phrases, section changes, verse/chorus energy and new-song reset.

**Diagnostics.** `open -g halo://record/15` writes 15 s of audio features and LED colors to `~/Library/Caches/Halo-build/frames.csv`; `defaults read local.halo.backlight debug.lightDelay` shows the delay breakdown.

## Shortcuts and automation

Halo handles `halo://` links, so Shortcuts (an **Open URLs** action), Siri (run the shortcut by name), Raycast and Terminal (`open -g halo://toggle`) can control it:

| Link | Effect |
|---|---|
| `halo://on`, `halo://off`, `halo://toggle` | Power |
| `halo://preset/<chill\|groove\|party\|club\|movie>` | Music preset (`movie` = Screen mode) |
| `halo://mode/<screen\|music\|auto\|color\|effect>` | Switch mode |
| `halo://color/ff8800` | Solid color (hex) |
| `halo://ambient/ffc080` | Auto mode's ambient color |
| `halo://brightness/40`, `/up`, `/down` | Brightness 1–100 |
| `halo://music/<spectrum\|party\|screen>` | Music mode with a style |
| `halo://motion/<off\|flow\|beat\|wave>` | Spectrum color motion |
| `halo://stereo/<on\|off>` | Follow stereo left/right |
| `halo://intensity/40` | Party intensity 0–100 |
| `halo://energy/<on\|off>` | Follow song energy |
| `halo://snare/<on\|off>`, `halo://hats/<on\|off>` | Snare/clap accents, hi-hat shimmer |
| `halo://synctest`, `halo://synctest/off` | Sync test: kicks + white flashes for lining up Fine-tune |
| `halo://palette/<rainbow\|fire\|ocean\|neon\|sunset\|forest\|ice\|custom>` | Music color palette |
| `halo://sensitivity/65`, `halo://smoothness/35` | Tuning for the current music style |
| `halo://effect/rainbow` | Built-in effect by name or index |
| `halo://speed/70` | Effect speed |
| `halo://display/lg`, `halo://display/main` | Follow a display (name match) |
| `halo://blackbars/off` | Black bar detection on/off |
| `halo://videosync/<on\|off>` | Bluetooth video sync on/off |
| `halo://calibrate` | Measure the speaker delay |
| `halo://settings` | Open the settings window |

## Bluetooth video sync

Bluetooth speakers play late, and macOS often underestimates by how much (Logi Z407: 352 ms measured, 123 ms reported), so video runs ahead of the sound. *Video sync* fixes this for players that honor Core Audio's device latency.

How it works: a small audio driver (`Driver/HaloSync.c`, an AudioServerPlugIn) adds an output device called **Halo Sync**. When the default output is a Bluetooth speaker, Halo makes Halo Sync the default output, forwards its audio to the speaker (lock-free ring buffer with drift-correcting resampling, `Sources/HaloAudio/Forwarder.c`), and has the driver report the speaker's real end-to-end delay as its latency. Players delay the picture by that amount. Volume and mute are mirrored to the speaker. Turning it off, quitting, or disconnecting the speaker restores the normal output. *Measure speaker delay* measures through Halo Sync while routed, so the reported figure covers the whole path.

Verified on a Logi Z407: 364 ms measured through Halo Sync (8/8 beeps, ±0). An AVPlayer test (beeps at known positions, heard by the mic, compared with the player's clock) put sound 13 ms behind the player clock with video sync on (≈ mic latency), and about 300 ms behind with it off.

- **Works:** Safari, QuickTime Player, TV, IINA and other AVFoundation/Core Audio players.
- **Doesn't help:** Chrome, Firefox and most games, which ignore device latency. The Bluetooth delay is unchanged there.
- The orange microphone dot shows while routing: Halo reads Halo Sync's audio through its input side.

Install the driver from Settings → *Video sync* → *Install driver*, or `Driver/install-driver.sh` (both ask for your password and restart Core Audio for a second). Remove it with `Driver/uninstall-driver.sh`.

## Hardware

The strip's controller is a Robobloq USB HID device, `1a86:fe07`, using the vendor interface on usage page `0xFF00`. It takes 64-byte reports and works with macOS's built-in USB support, so no driver is needed. The protocol notes come from OpenRGB's `RobobloqLightStripController`; this app's code is written separately.

| Packet | Layout |
|---|---|
| Short `RB` | `52 42 <len> <idx> <cmd…> <sum>` (`len` = whole packet, `sum` = byte sum & 0xFF) |
| Long `SC` | `53 43 <len16 BE> <idx> <cmd> <payload…> <sum>`, split into 64-byte reports |
| `0x80` | Sync-screen frame: (start, R, G, B, end) ranges, 1-based, end inclusive |
| `0x82` | Device info. Reply: `[8]` size in inches, `[11]` LED count, `[21..23]` firmware |
| `0x85 02 n` | Built-in effect `n` (0–6) |
| `0x85 03 07` | Microphone effect Circles (not used by Halo). Other codes tried (00–0D, 10–13) do nothing; the controller's ♫ button cycles its other sound effects. |
| `0x98 e l` | (Vendor app, not used by Halo.) "Computer rhythm": drives sound effect `e` with level `l` (0–100), sent every 40 ms from Windows' audio peak meter. Needs firmware ≥ 1.8.2. |
| `0x86` | Color ranges |
| `0x87 b` | Brightness (1–255) |
| `0x8A s` | Effect speed (0 = fast, 100 = slow) |
| `0x93 00` | Stops the controller from asking the PC to open the vendor URL. It also clears a stalled parser: after a half-written or bad packet, the controller ignores frames until it gets this. Halo sends it on every mode change and every 3 s while syncing. |
| `0x97` | Off (also send black) |

## Build

```bash
./build.sh   # builds, signs, quits the running copy and installs ~/Applications/Halo.app
```

This needs only the Xcode Command Line Tools (Swift 5.10+), not full Xcode. The bundle is built and signed in `~/Library/Caches/Halo-build`, outside iCloud Drive, because iCloud adds Finder metadata that `codesign` rejects.

### Signing

macOS ties Screen Recording and Microphone permission to the app's signature. An ad-hoc signature changes with every build, so the permission would have to be granted again each time. `build.sh` therefore signs with a local self-signed certificate, **Halo Local Signing**, kept in its own keychain at `~/Library/Caches/Halo-build/signing/`. That makes the requirement `identifier "local.halo.backlight" and certificate leaf = …`, which stays the same across builds. The keychain is added to the search list only while `codesign` runs.

One-time setup (already done on this Mac): create the certificate and keychain, then trust it for code signing (needs your password):

```bash
security add-trusted-cert -p codeSign -k "$HOME/Library/Caches/Halo-build/signing/halo-signing.keychain-db" "$HOME/Library/Caches/Halo-build/signing/cert.pem"
```

Without that keychain, `build.sh` falls back to ad-hoc signing.

## First run

1. Open Halo. A strip icon appears in the menu bar.
2. Screen mode needs **System Settings → Privacy & Security → Screen Recording → Halo** turned on. After that, quit and reopen Halo.
3. Open **Settings… → Show test pattern**. The first 5 LEDs should be red, the two top corners green and the last 5 LEDs blue. If red shows up at the bottom-right instead, set *LED 1 starts at* to Bottom-right.

While Halo is streaming the screen, the controller's own buttons don't respond. That's how the hardware behaves, not a fault.
