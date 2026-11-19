# Halo

A small macOS menu-bar app for the AKKLED monitor backlight strip. It replaces the vendor app and needs no activation or internet connection.

| Mode | What it does |
|---|---|
| **Screen** | Mirrors the edges of the chosen display at about 30 fps. Black bars (letterbox/pillarbox) are skipped, so the side LEDs keep showing the picture: an edge column counts as a bar once it has stayed pure black (≤12) for about a second in the middle of the frame, which ignores player titles and controls. Bars are taken as equal pairs at the narrower side's width, and only realistic sizes count (3–30 % per side, 3–25 % top/bottom). Verified with a synthetic 16:9-on-21:9 test: bars read 26 columns against 27.5 expected, and held through dark edges and dark scenes. Diagnostics: `defaults read local.halo.backlight debug.blackBars`. |
| **Music** | Follows the Mac's audio output: *Spectrum* (bass left → treble right), *Pulse* (breathes with the music, color steps on each beat), *Party* (club lights: hard hits on every kick, a new color per beat, a new pattern every 16 beats, optional strobe) or *Screen* (screen colors, brightness follows the music). Spectrum, Pulse and Party take a color palette (Rainbow, Fire, Ocean, Neon, Sunset, Forest, Ice, or a custom two-color gradient). Each style keeps its own sensitivity and smoothness. Beats are detected straight from the samples (~5 ms blocks) and rendered immediately. Lights are held back to match the speaker: by default by the latency macOS reports, or by a microphone measurement (*Measure speaker delay* plays 8 beeps and finds them in the built-in mic's recording with a matched filter), plus a manual fine-tune. Bluetooth speakers often play later than macOS reports: a Logi Z407 measured 352 ms against 123 ms reported. |
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
| `halo://palette/<rainbow\|fire\|ocean\|neon\|sunset\|forest\|ice\|custom>` | Music color palette |
| `halo://sensitivity/65`, `halo://smoothness/35` | Tuning for the current music style |
| `halo://effect/rainbow`, `halo://pickup/sparkle` | Built-in effect by name or index |
| `halo://speed/70` | Effect speed |
| `halo://display/lg`, `halo://display/main` | Follow a display (name match) |
| `halo://blackbars/off` | Black bar detection on/off |
| `halo://settings` | Open the settings window |

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
