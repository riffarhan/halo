import AppKit
import SwiftUI

// MARK: Menu bar window

struct MenuView: View {
    @EnvironmentObject private var lights: LightController
    private let modeColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Halo").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(lights.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(lights.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Power", isOn: $lights.settings.isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            LazyVGrid(columns: modeColumns, spacing: 6) {
                ForEach(LightMode.allCases) { mode in
                    ChoiceButton(selected: lights.settings.mode == mode) {
                        lights.settings.mode = mode
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: mode.symbol).font(.system(size: 15))
                            Text(mode.title).font(.caption)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            Group {
                switch lights.settings.mode {
                case .screen: ScreenSection()
                case .music: MusicSection()
                case .auto: AutoSection()
                case .color: ColorSection()
                case .effect: EffectSection()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LabeledSlider(title: "Brightness", value: $lights.settings.brightness, range: 1 ... 100, format: "%.0f%%")

            if lights.testPatternActive || lights.whitePreviewActive {
                Button(lights.testPatternActive ? "End test pattern" : "End white preview") { lights.endHolds() }
            }

            Divider()
            HStack {
                Button("Settings…") { SettingsWindow.shared.show() }
                Spacer()
                Button("Quit Halo") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 330)
    }
}

private struct ScreenSection: View {
    @EnvironmentObject private var lights: LightController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisplayPicker()
            Toggle("Ignore black bars (movies)", isOn: $lights.settings.picture.blackBars)
            CaptureErrorView()
        }
    }
}

private struct MusicSection: View {
    @EnvironmentObject private var lights: LightController
    @AppStorage("ui.musicAdvanced") private var showAdvanced = false
    @AppStorage("ui.speakerSync") private var showSpeakerSync = false

    private var preset: Binding<Preset?> {
        Binding(get: { Preset.current(lights.settings) },
                set: { if let p = $0 { p.apply(to: &lights.settings) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Preset", selection: preset) {
                ForEach(Preset.allCases) { Text($0.title).tag(Optional($0)) }
                if Preset.current(lights.settings) == nil { Text("Custom").tag(Preset?.none) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(Preset.current(lights.settings)?.summary
                 ?? "Your own mix of settings (see Advanced). Pick a preset to go back to one.")
                .font(.caption).foregroundStyle(.secondary)
            Text(musicStatus).font(.caption2).foregroundStyle(.secondary)
            if lights.settings.musicStyle != .screen { PalettePicker() }
            if lights.settings.musicStyle == .party {
                Toggle("Strobe on big hits", isOn: $lights.settings.partyStrobe)
                    .disabled(lights.settings.partyIntensity <= 60)
                Text("Short white flashes at full intensity. Leave off if anyone nearby is sensitive to flashing light.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advanced.padding(.top, 4) }
            DisclosureGroup("Speaker sync", isExpanded: $showSpeakerSync) { speakerSync.padding(.top, 4) }
            if lights.settings.musicStyle == .screen { DisplayPicker() }
            CaptureErrorView()
        }
    }

    private var musicStatus: String {
        let tempo = lights.musicBPM > 0 ? String(format: "%.0f BPM", lights.musicBPM) : "Finding the beat…"
        let part = lights.musicEnergy < 0.35 ? "calm part" : lights.musicEnergy < 0.75 ? "building" : "biggest part"
        return "\(tempo) · \(part) of the song"
    }

    @ViewBuilder private var advanced: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Style", selection: $lights.settings.musicStyle) {
                ForEach(MusicStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
            if lights.settings.musicStyle == .spectrum {
                Picker("Color motion", selection: $lights.settings.spectrumMotion) {
                    ForEach(SpectrumMotion.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(motionCaption).font(.caption2).foregroundStyle(.secondary)
            }
            if lights.settings.musicStyle == .party {
                LabeledSlider(title: "Intensity", value: $lights.settings.partyIntensity, range: 0 ... 100, format: "%.0f")
                Text("Low: colors fade into each other on the beat and the strip never goes dark. High: hard club hits.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Snare/clap accents", isOn: $lights.settings.snareAccents)
            Text("Kicks drive the colors; each snare or clap adds a short white flash across the top middle.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Hi-hat shimmer", isOn: $lights.settings.hatShimmer)
            Text("Hi-hats add a faint sparkle on the treble side of the strip.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Follow song energy", isOn: $lights.settings.songEnergy)
            Text("Calmer in verses and breakdowns, bigger in choruses and drops (Spectrum).")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Follow stereo (left/right)", isOn: $lights.settings.stereo)
            Text("When the music leans left or right, the other side of the strip dims.")
                .font(.caption2).foregroundStyle(.secondary)
            LabeledSlider(title: "Sensitivity", value: $lights.settings.tuning.sensitivity, range: 0 ... 100, format: "%.0f")
            LabeledSlider(title: "Smoothness", value: $lights.settings.tuning.smoothness, range: 0 ... 100, format: "%.0f")
        }
    }

    @ViewBuilder private var speakerSync: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Match speaker delay automatically", isOn: $lights.settings.autoSpeakerSync)
            LabeledSlider(title: lights.settings.autoSpeakerSync ? "Fine-tune" : "Light delay",
                          value: $lights.settings.lightDelayMs,
                          range: lights.settings.autoSpeakerSync ? -150 ... 250 : 0 ... 400, format: "%+.0f ms")
            Text(syncHint).font(.caption2).foregroundStyle(.secondary)
            Button(lights.syncTesting ? "Stop sync test" : "Sync test (kicks + white flashes, 30 s)") {
                lights.syncTesting ? lights.stopSyncTest() : lights.startSyncTest()
            }
            if lights.syncTesting {
                Text("Move the slider above while it runs until each flash lands with its kick. Light late → slide left; light early → slide right.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if lights.settings.autoSpeakerSync {
                Button(lights.calibrating ? "Measuring…" : "Measure speaker delay (plays 8 beeps)") { lights.measureSpeaker() }
                    .disabled(lights.calibrating)
                if let msg = lights.calibrationMessage {
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var motionCaption: String {
        switch lights.settings.spectrumMotion {
        case .off: "Colors stay fixed: bass color on the left, treble color on the right."
        case .flow: "The palette drifts slowly along the strip."
        case .beat: "Colors follow the bass: they flow while bass plays and jump on every kick, further the harder it hits."
        case .wave: "Like Beat, but each kick's new colors start at the bass end and travel across the strip."
        }
    }

    private var syncHint: String {
        var parts: [String] = []
        if let route = lights.videoSync.route {
            parts.append(String(format: "Video sync: sound goes through Halo Sync to %@, %.0f ms late in total.",
                                route.targetName, lights.videoSync.reportedLatencyMs))
        } else if let out = lights.outputDevice {
            if let measured = lights.settings.measuredLatency[out.name] {
                parts.append(String(format: "%@ plays sound %.0f ms late (measured).", out.name, measured))
            } else {
                parts.append(String(format: "%@%@ plays sound %.0f ms late (reported by macOS).", out.name, out.bluetooth ? " (Bluetooth)" : "", out.latencyMs))
            }
        }
        if let ms = lights.audioLatencyMs {
            parts.append(String(format: "Audio reaches Halo after %.0f ms.", max(0, ms)))
        }
        parts.append(String(format: "Writing a frame to the strip takes %.0f ms.", lights.frameWriteMs))
        parts.append(String(format: "Lights held back %.0f ms.", lights.effectiveLightDelayMs))
        parts.append("Lights before the beat → slide right. Lights after it → slide left. Sync test (pause your music first) makes it easy to judge.")
        return parts.joined(separator: " ")
    }

    private var caption: String {
        switch lights.settings.musicStyle {
        case .spectrum: "Bass on the left, treble on the right, colored along the palette below."
        case .party: "Club lights: hard hits on every kick, a new color each beat, and a new pattern every 16 beats."
        case .screen: "Screen colors, with brightness following the music."
        }
    }
}

private struct PalettePicker: View {
    @EnvironmentObject private var lights: LightController
    private let columns = [GridItem(.adaptive(minimum: 66), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(MusicPalette.allCases) { palette in
                    let selected = lights.settings.musicPalette == palette
                    Button { lights.settings.musicPalette = palette } label: {
                        VStack(spacing: 3) {
                            Capsule()
                                .fill(LinearGradient(colors: stops(palette).map { Color(rgb: $0) },
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(height: 12)
                                .overlay(Capsule().strokeBorder(.primary.opacity(selected ? 0.9 : 0.1), lineWidth: selected ? 2 : 1))
                            Text(palette.title).font(.caption2)
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if lights.settings.musicPalette == .custom {
                HStack {
                    ColorPicker("Bass", selection: rgbBinding(\.paletteFrom), supportsOpacity: false)
                    Spacer()
                    ColorPicker("Treble", selection: rgbBinding(\.paletteTo), supportsOpacity: false)
                }
                .font(.callout)
            }
        }
    }

    private func stops(_ p: MusicPalette) -> [RGB] {
        p.stops(customFrom: lights.settings.paletteFrom, customTo: lights.settings.paletteTo)
    }

    private func rgbBinding(_ key: WritableKeyPath<Settings, RGB>) -> Binding<Color> {
        Binding(get: { Color(rgb: lights.settings[keyPath: key]) },
                set: { lights.settings[keyPath: key] = RGB(color: $0) })
    }
}

private struct AutoSection: View {
    @EnvironmentObject private var lights: LightController
    private let presets: [RGB] = [
        RGB(r: 255, g: 120, b: 40), RGB(r: 255, g: 160, b: 80), RGB(r: 255, g: 200, b: 140),
        RGB(r: 255, g: 235, b: 215), RGB(r: 255, g: 255, b: 255),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: lights.fullscreenDetected ? "play.rectangle.fill" : "lamp.desk")
                Text(lights.fullscreenDetected ? "Fullscreen detected — syncing the screen" : "Nothing fullscreen — ambient light")
            }
            .font(.callout)
            Text("Ambient color").font(.caption).foregroundStyle(.secondary)
            Swatches(presets: presets, selection: $lights.settings.ambientColor)
            DisplayPicker()
            CaptureErrorView()
        }
    }
}

private struct ColorSection: View {
    @EnvironmentObject private var lights: LightController

    private let presets: [RGB] = [
        RGB(r: 255, g: 140, b: 40), RGB(r: 255, g: 255, b: 255), RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 90, b: 0),
        RGB(r: 0, g: 255, b: 60), RGB(r: 0, g: 200, b: 255), RGB(r: 0, g: 40, b: 255), RGB(r: 170, g: 0, b: 255),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Swatches(presets: presets, selection: $lights.settings.color)
            HueSlider(color: $lights.settings.color)
        }
    }
}

private struct EffectSection: View {
    @EnvironmentObject private var lights: LightController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NameGrid(names: Robobloq.effectNames, selection: $lights.settings.effect)
            LabeledSlider(title: "Speed", value: $lights.settings.speed, range: 0 ... 100, format: "%.0f")
        }
    }
}

private struct CaptureErrorView: View {
    @EnvironmentObject private var lights: LightController

    var body: some View {
        if let error = lights.syncError {
            Text(error).font(.caption).foregroundStyle(.orange)
            if lights.needsScreenPermission {
                HStack {
                    Button("Grant permission") { lights.requestScreenPermission() }
                    Button("Retry") { lights.apply() }
                }
            }
        }
    }
}

private struct DisplayPicker: View {
    @EnvironmentObject private var lights: LightController

    var body: some View {
        if lights.displays.count > 1 {
            Picker("Display", selection: Binding(
                get: { lights.effectiveDisplayID },
                set: { lights.settings.displayID = $0 }
            )) {
                ForEach(lights.displays) { Text($0.name).tag($0.id) }
            }
        }
    }
}

// MARK: Settings window

struct SettingsView: View {
    @EnvironmentObject private var lights: LightController

    var body: some View {
        Form {
            Section {
                if lights.displays.count > 1 {
                    Picker("Follow display", selection: Binding(
                        get: { lights.effectiveDisplayID },
                        set: { lights.settings.displayID = $0 }
                    )) {
                        ForEach(lights.displays) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("Mode", selection: $lights.settings.mode) {
                    ForEach(LightMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Lights on", isOn: $lights.settings.isOn)
            } header: { Text("Lights") }

            Section {
                Picker("LED 1 starts at", selection: $lights.settings.layout.start) {
                    ForEach(StartCorner.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Left side: \(lights.settings.layout.left)", value: $lights.settings.layout.left, in: 0 ... 150)
                Stepper("Top: \(lights.settings.layout.top)", value: $lights.settings.layout.top, in: 0 ... 200)
                Stepper("Right side: \(lights.settings.layout.right)", value: $lights.settings.layout.right, in: 0 ... 150)
                Stepper("Bottom: \(lights.settings.layout.bottom)", value: $lights.settings.layout.bottom, in: 0 ... 200)
                if let info = lights.info, info.ledCount != lights.settings.layout.total {
                    Text("Layout has \(lights.settings.layout.total) LEDs; the strip reports \(info.ledCount).")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Auto-fit to display") { lights.autoLayout() }
                    Button("Show test pattern") { lights.showTestPattern() }
                        .disabled(!lights.connected)
                }
                Text("Test pattern: first 5 LEDs red, top corners green, last 5 blue. Sides are as seen from the front of the screen.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Strip layout") }

            Section {
                Toggle("Ignore black bars (letterbox / pillarbox)", isOn: $lights.settings.picture.blackBars)
                LabeledSlider(title: "Edge depth", value: $lights.settings.layout.depth, range: 0.03 ... 0.4, format: "%.2f")
                LabeledSlider(title: "Saturation", value: $lights.settings.picture.saturation, range: 0.5 ... 2.5, format: "%.2f")
                LabeledSlider(title: "Gamma", value: $lights.settings.picture.gamma, range: 0.8 ... 2.8, format: "%.2f")
                LabeledSlider(title: "Smoothing", value: $lights.settings.picture.smoothing, range: 0 ... 0.9, format: "%.2f")
                Picker("Frame rate", selection: $lights.settings.picture.fps) {
                    ForEach([15, 24, 30, 45, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Detail", selection: $lights.settings.picture.maxRanges) {
                    Text("Every LED").tag(max(lights.ledCount, 1))
                    Text("34 zones (vendor app)").tag(34)
                    Text("16 zones").tag(16)
                }
            } header: { Text("Screen sync") }

            Section {
                LabeledSlider(title: "Red", value: $lights.settings.picture.whiteBalance.r, range: 0.3 ... 1, format: "%.2f")
                LabeledSlider(title: "Green", value: $lights.settings.picture.whiteBalance.g, range: 0.3 ... 1, format: "%.2f")
                LabeledSlider(title: "Blue", value: $lights.settings.picture.whiteBalance.b, range: 0.3 ... 1, format: "%.2f")
                HStack {
                    Button(lights.whitePreviewActive ? "Stop white preview" : "Preview white on the strip") {
                        lights.toggleWhitePreview()
                    }
                    .disabled(!lights.connected)
                    Button("Reset") { lights.settings.picture.whiteBalance = WhiteBalance() }
                }
                Text("Turn on the preview, then lower the channel that's too strong (usually blue) until the strip looks neutral white. Applies to every mode except the controller's built-in effects.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("White balance") }

            VideoSyncSection()

            Section {
                ShortcutRow(url: "halo://toggle", note: "On / off")
                ShortcutRow(url: "halo://mode/auto", note: "screen · music · auto · color · effect")
                ShortcutRow(url: "halo://color/ff8800", note: "Solid color (hex)")
                ShortcutRow(url: "halo://brightness/40", note: "1–100, or up / down")
                ShortcutRow(url: "halo://music/party", note: "spectrum · party · screen")
                ShortcutRow(url: "halo://effect/rainbow", note: "Built-in effect by name")
                ShortcutRow(url: "halo://display/lg", note: "Follow a display by name, or main")
                ShortcutRow(url: "halo://videosync/on", note: "Bluetooth video sync on / off")
                Text("In Shortcuts, add an Open URLs action with one of these. Siri can then run that shortcut by name. From Terminal: open -g halo://toggle")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Shortcuts & automation") }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { lights.launchAtLogin }, set: { lights.launchAtLogin = $0 }))
                if let err = lights.launchAtLoginError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Turn off when the Mac or display sleeps", isOn: $lights.settings.offOnSleep)
                Toggle("Turn off when quitting Halo", isOn: $lights.settings.offOnQuit)
            } header: { Text("General") }

            if let info = lights.info {
                Section {
                    LabeledContent("LEDs", value: "\(info.ledCount)")
                    LabeledContent("Kit size", value: "\(info.sizeInches)\"")
                    LabeledContent("Firmware", value: info.firmware)
                    LabeledContent("Device ID", value: "\(info.id) · \(info.uuid)")
                } header: { Text("Device") }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 600)
    }
}

private struct VideoSyncSection: View {
    @EnvironmentObject private var lights: LightController

    var body: some View {
        Section {
            Toggle("Keep video in sync with Bluetooth speakers", isOn: $lights.settings.videoSync)
            if !lights.videoSync.driverInstalled {
                HStack {
                    Text("Needs the Halo Sync audio driver.").font(.callout)
                    Spacer()
                    Button(lights.installingDriver ? "Installing…" : "Install driver…") { lights.installVideoSyncDriver() }
                        .disabled(lights.installingDriver)
                }
            } else if let route = lights.videoSync.route {
                LabeledContent("Speaker", value: route.targetName)
                LabeledContent("Delay told to apps", value: String(format: "%.0f ms%@", lights.videoSync.reportedLatencyMs,
                                                                   lights.settings.videoSyncLatency[route.targetName] == nil ? " (estimated)" : " (measured)"))
                LabeledContent("Forwarding buffer", value: String(format: "%.0f ms%@", lights.videoSync.bufferMs,
                                                                  lights.videoSync.underruns > 0 ? " · \(lights.videoSync.underruns) dropouts" : ""))
                Button(lights.calibrating ? "Measuring…" : "Measure delay (plays 8 beeps)") { lights.measureSpeaker() }
                    .disabled(lights.calibrating)
                if let msg = lights.calibrationMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            } else if lights.settings.videoSync {
                Text("Waiting for Bluetooth: it switches on when a Bluetooth speaker or headphones are the sound output.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let err = lights.videoSyncError ?? lights.videoSync.lastError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            Text("Bluetooth plays sound late but tells macOS a much smaller delay, so video runs ahead of the voices. With this on, Halo sends the sound through its Halo Sync device, which reports the real (measured) delay, so players hold the picture back to match. Works in Safari (YouTube, Netflix), QuickTime, TV, Music and IINA; Chrome and games ignore it. macOS shows the orange microphone dot while it runs, because Halo reads the sound back from Halo Sync. Halo never listens to the microphone except during Measure.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Video sync (Bluetooth)") }
    }
}

private struct ShortcutRow: View {
    var url: String
    var note: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }
}

// MARK: Components

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range)
        }
    }
}

private struct ChoiceButton<Label: View>: View {
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07)))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NameGrid: View {
    var names: [String]
    @Binding var selection: Int
    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                ChoiceButton(selected: selection == i) { selection = i } label: { Text(name) }
            }
        }
    }
}

private struct Swatches: View {
    var presets: [RGB]
    @Binding var selection: RGB

    var body: some View {
        HStack(spacing: 8) {
            ForEach(presets, id: \.self) { c in
                Button { selection = c } label: {
                    Circle()
                        .fill(Color(rgb: c))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(.primary.opacity(selection == c ? 0.9 : 0.15),
                                                       lineWidth: selection == c ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help("#\(c.hex)")
            }
            ColorPicker("Custom", selection: Binding(
                get: { Color(rgb: selection) },
                set: { selection = RGB(color: $0) }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }
}

private struct HueSlider: View {
    @Binding var color: RGB

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                    startPoint: .leading, endPoint: .trailing))
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .shadow(radius: 1)
                    .frame(width: 16, height: 16)
                    .offset(x: CGFloat(hue) * (geo.size.width - 16))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let h = min(max(g.location.x / geo.size.width, 0), 0.999)
                color = RGB(color: Color(hue: h, saturation: 1, brightness: 1))
            })
        }
        .frame(height: 16)
    }

    private var hue: Double {
        var h: CGFloat = 0
        NSColor(Color(rgb: color)).usingColorSpace(.sRGB)?.getHue(&h, saturation: nil, brightness: nil, alpha: nil)
        return Double(h)
    }
}

extension Color {
    init(rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

extension RGB {
    init(color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func byte(_ v: CGFloat) -> UInt8 { UInt8(clamping: Int((min(max(v, 0), 1) * 255).rounded())) }
        self.init(r: byte(c.redComponent), g: byte(c.greenComponent), b: byte(c.blueComponent))
    }
}
