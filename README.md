# Halo

A small macOS menu-bar app for the AKKLED monitor backlight strip. It replaces the vendor app and needs no activation or internet connection.

| Mode | What it does |
|---|---|
| **Screen** | Mirrors the edges of the chosen display at about 30 fps. Black bars (letterbox/pillarbox) are skipped, so the side LEDs keep showing the picture: an edge column counts as a bar once it has stayed pure black (≤12) for about a second in the middle of the frame, which ignores player titles and controls. Bars are taken as equal pairs at the narrower side's width, and only realistic sizes count (3–30 % per side, 3–25 % top/bottom). Verified with a synthetic 16:9-on-21:9 test: bars read 26 columns against 27.5 expected, and held through dark edges and dark scenes. Diagnostics: `defaults read local.halo.backlight debug.blackBars`. |
| **Music** | Follows the Mac's audio output: *Spectrum* (bass left → treble right), *Pulse* (breathes with the music, color steps on each beat), *Party* (club lights: a new color per beat, a new pattern every 16 beats, full hits on every kick; *Intensity* runs from 100 = the original club look with hard cuts and optional strobe down to Soft = colors crossfade on the beat and the strip never goes dark) or *Screen* (screen colors, brightness follows the music). Spectrum can move its palette along the strip (*Color motion*: Off; Flow = slow drift; Beat = follows the bass: every kick lifts the whole strip's brightness for ~0.2 s (no color flash), the palette flows while bass plays, faster the heavier it is, and jumps on every kick by how hard it hits, measured against the loudest kicks of the last ~20 s, with a bigger jump every 4th beat; Wave = Beat, but each kick's colors start at the bass end and travel across the strip in ~0.6 s). *Follow song energy* scales the beat effects with the part of the song: the last ~3 s of loudness and bass against the biggest part heard so far (forgetting 3 dB a minute), so verses and breakdowns play calmer (×0.55) and choruses and drops bigger (×1.45). Party is left as set, so Intensity 100 is always the original club look. In a synthetic song, verse 2 read 0.12 and choruses 1.0; the first verse can read high until the first chorus shows the song's range. Deep, hard kicks bloom further over the ~2 frames after the hit. *Follow stereo* dims the side of the strip away from the louder channel (up to 85 % at 12 dB difference), so music panned left or right lights that side. Spectrum, Pulse and Party take a color palette (Rainbow, Fire, Ocean, Neon, Sunset, Forest, Ice, or a custom two-color gradient). Each style keeps its own sensitivity and smoothness. Smoothness only softens small wobbles and how lights fade out; a rise as big as a kick lands in the same frame, so high smoothness doesn't make beats late. Beats are detected straight from the samples (~5 ms steps, level measured over one ~21 ms bass cycle) and rendered immediately. A kick must rise sharply and beat the fading peak of the previous one, so a long or wobbling 808 note counts once. Tested: realistic 808 notes 4/4, alternating loud/half kicks 8/8, kicks every 0.25 s 12/12. Diagnostics: `open -g halo://record/15` writes 15 s of audio features and LED colors to `~/Library/Caches/Halo-build/frames.csv`. Lights are held back to match the speaker: by default by the latency macOS reports, or by a microphone measurement (*Measure speaker delay* plays 8 beeps and finds them in the built-in mic's recording with a matched filter), plus a manual fine-tune. The delay is `speaker − time for audio to reach Halo − USB write time (measured, ~7 ms)`; what the strip's controller adds can't be measured from the Mac, so *Sync test* plays a kick every 0.6 s and flashes the strip white through the same capture → beat detection → delay path as music (including Halo's own audio only during the test). Move Fine-tune until flash and kick land together. Diagnostics: `defaults read local.halo.backlight debug.lightDelay`. Bluetooth speakers often play later than macOS reports: a Logi Z407 measured 352 ms against 123 ms reported. |
| **Auto** | Screen sync while another app is fullscreen on the chosen display (video, game), otherwise a warm ambient color |
| **Color** | One solid color |
| **Effect** | The controller's 7 built-in animations, with speed control |
| **Pickup** | The controller's 7 sound-reactive effects, using its own microphone |

Also included: per-display selection, white balance with a live white preview, brightness, launch at login, lights off on sleep or quit, and a layout test pattern. Opening Halo again from Finder or Spotlight opens its settings window.

## Shortcuts and automation

Halo handles `halo://` links, so Shortcuts (an **Open URLs** action), Siri (run the shortcut by name), Raycast and Terminal (`open -g halo://toggle`) can control it:

| Link | Effect |
|---|---|
| `halo://on`, `halo://off`, `halo://toggle` | Power |
| `halo://mode/<screen\|music\|auto\|color\|effect\|pickup>` | Switch mode |
| `halo://color/ff8800` | Solid color (hex) |
| `halo://ambient/ffc080` | Auto mode's ambient color |
| `halo://brightness/40`, `/up`, `/down` | Brightness 1–100 |
| `halo://music/<spectrum\|pulse\|party\|screen>` | Music mode with a style |
| `halo://motion/<off\|flow\|beat\|wave>` | Spectrum color motion |
| `halo://stereo/<on\|off>` | Follow stereo left/right |
| `halo://intensity/40` | Party intensity 0–100 |
| `halo://energy/<on\|off>` | Follow song energy |
| `halo://synctest`, `halo://synctest/off` | Sync test: kicks + white flashes for lining up Fine-tune |
| `halo://palette/<rainbow\|fire\|ocean\|neon\|sunset\|forest\|ice\|custom>` | Music color palette |
| `halo://sensitivity/65`, `halo://smoothness/35` | Tuning for the current music style |
| `halo://effect/rainbow`, `halo://pickup/sparkle` | Built-in effect by name or index |
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
| `0x85 03 07` | Microphone ("Pickup") effect Circles. Other codes tried (00–0D, 10–13) do nothing; the controller's ♫ button cycles its other sound effects. |
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
