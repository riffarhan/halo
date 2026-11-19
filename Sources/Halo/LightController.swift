import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

enum LightMode: String, Codable, CaseIterable, Identifiable {
    case screen, music, auto, color, effect, pickup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screen: "Screen"
        case .music: "Music"
        case .auto: "Auto"
        case .color: "Color"
        case .effect: "Effect"
        case .pickup: "Pickup"
        }
    }
    var symbol: String {
        switch self {
        case .screen: "display"
        case .music: "music.note"
        case .auto: "wand.and.stars"
        case .color: "paintpalette"
        case .effect: "sparkles"
        case .pickup: "mic"
        }
    }
}

struct Settings: Codable, Equatable {
    var isOn = true
    var mode: LightMode = .screen
    var color = RGB(r: 255, g: 140, b: 40)
    /// Used by Auto mode when nothing is fullscreen.
    var ambientColor = RGB(r: 255, g: 160, b: 80)
    var brightness = 80.0
    var effect = 0
    var speed = 50.0
    var pickupEffect = 0
    var pickupSensitivity = 50.0
    var musicStyle: MusicStyle = .spectrum
    /// Sensitivity/smoothness per music style, keyed by MusicStyle.rawValue.
    var musicTuning: [String: MusicTuning] = MusicTuning.recommended
    var musicPalette: MusicPalette = .rainbow
    var paletteFrom = RGB(r: 255, g: 0, b: 120)
    var paletteTo = RGB(r: 0, g: 200, b: 255)
    var partyStrobe = false
    var spectrumMotion: SpectrumMotion = .beat
    /// Manual fine-tune added on top of the automatic speaker match (can be negative).
    var lightDelayMs = 0.0
    /// Hold Music lights back by the speaker's reported latency (Bluetooth plays sound late).
    var autoSpeakerSync = true
    /// Microphone-measured speaker latency in ms, by output device name. Preferred over Core Audio's figure.
    var measuredLatency: [String: Double] = [:]
    var displayID: UInt32?
    var layout = LedLayout()
    var picture = PictureSettings()
    var offOnSleep = true
    var offOnQuit = true
}

struct MusicTuning: Codable, Equatable {
    var sensitivity: Double
    var smoothness: Double

    /// Spectrum and Pulse read best soft; Party needs hits that land and drop away fast.
    static let recommended: [String: MusicTuning] = [
        MusicStyle.spectrum.rawValue: MusicTuning(sensitivity: 50, smoothness: 70),
        MusicStyle.pulse.rawValue: MusicTuning(sensitivity: 55, smoothness: 60),
        MusicStyle.party.rawValue: MusicTuning(sensitivity: 65, smoothness: 35),
        MusicStyle.screen.rawValue: MusicTuning(sensitivity: 50, smoothness: 60),
    ]
}

extension Settings {
    /// Tuning for the current music style.
    var tuning: MusicTuning {
        get { musicTuning[musicStyle.rawValue] ?? MusicTuning.recommended[musicStyle.rawValue] ?? MusicTuning(sensitivity: 50, smoothness: 60) }
        set { musicTuning[musicStyle.rawValue] = newValue }
    }
}

struct OutputDevice: Equatable {
    var name: String
    var bluetooth: Bool
    var latencyMs: Double
}

struct DisplayChoice: Identifiable, Hashable {
    var id: CGDirectDisplayID
    var name: String
    var aspect: Double
}

@MainActor
final class LightController: ObservableObject {
    @Published var settings: Settings {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published private(set) var connected = false
    @Published private(set) var info: DeviceInfo?
    @Published private(set) var syncError: String?
    @Published private(set) var needsScreenPermission = false
    @Published private(set) var testPatternActive = false
    @Published private(set) var whitePreviewActive = false
    @Published private(set) var displays: [DisplayChoice] = []
    /// Auto mode: something is fullscreen on the chosen display right now.
    @Published private(set) var fullscreenDetected = false
    /// How late macOS delivers audio to Halo, in ms (Music mode only).
    @Published private(set) var audioLatencyMs: Double?
    /// Name and connection type of the current sound output, e.g. "Logi Z407 (Bluetooth)".
    @Published private(set) var outputDevice: OutputDevice?
    /// What Music mode actually holds the lights back by: auto speaker match + manual fine-tune.
    @Published private(set) var effectiveLightDelayMs = 0.0
    @Published var launchAtLoginError: String?

    private let device = RobobloqDevice()
    private lazy var engine = SyncEngine(device: device)
    private var asleep = false
    private var applyTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var autoTimer: Timer?
    private static let defaultsKey = "settings.v1"

    init() {
        settings = Self.loadSettings()
        refreshDisplays()

        device.onConnectionChange = { [weak self] up in
            MainActor.assumeIsolated { self?.connectionChanged(up) }
        }
        device.onDeviceInfo = { [weak self] info in
            MainActor.assumeIsolated { self?.received(info) }
        }
        engine.onAudioLatency = { [weak self] ms in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioLatencyMs = ms
                let device = Self.currentOutputDevice()
                if device != self.outputDevice { self.outputDevice = device }
                self.refreshLightDelay()
            }
        }
        engine.onStreamError = { [weak self] error in
            MainActor.assumeIsolated {
                self?.syncError = "Capture stopped: \(error.localizedDescription)"
            }
        }
        device.start()
        observeSystem()
        startAutoWatcher()
    }

    // MARK: Persistence

    /// Saved settings merged over the defaults, so settings added in newer versions keep their defaults.
    private static func loadSettings() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(Settings()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]
        else { return Settings() }
        func merge(_ a: inout [String: Any], _ b: [String: Any]) {
            for (k, v) in b {
                if var ad = a[k] as? [String: Any], let bd = v as? [String: Any] {
                    merge(&ad, bd); a[k] = ad
                } else {
                    a[k] = v
                }
            }
        }
        merge(&merged, saved)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(Settings.self, from: mergedData)
        else { return Settings() }
        return settings
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Derived

    var ledCount: Int { info?.ledCount ?? settings.layout.total }

    var statusText: String {
        guard connected else { return "Not connected — plug in the strip" }
        guard let info else { return "Connected" }
        return "Connected · \(info.ledCount) LEDs · fw \(info.firmware)"
    }

    var effectiveDisplayID: CGDirectDisplayID {
        if let id = settings.displayID, displays.contains(where: { $0.id == id }) { return id }
        return CGMainDisplayID()
    }

    var usesScreenCapture: Bool { [.screen, .music, .auto].contains(settings.mode) }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = error.localizedDescription
            }
            objectWillChange.send()
        }
    }

    private func wb(_ c: RGB) -> RGB { settings.picture.whiteBalance.apply(c) }

    private var engineConfig: EngineConfig {
        EngineConfig(
            render: settings.mode == .music ? .music(settings.musicStyle) : .screen,
            layout: settings.layout,
            picture: settings.picture,
            musicSensitivity: settings.tuning.sensitivity,
            musicSmoothness: settings.tuning.smoothness,
            palette: settings.musicPalette.stops(customFrom: settings.paletteFrom, customTo: settings.paletteTo),
            strobe: settings.partyStrobe,
            spectrumMotion: settings.spectrumMotion,
            lightDelayMs: effectiveLightDelayMs
        )
    }

    // MARK: Device events

    private func connectionChanged(_ up: Bool) {
        NSLog("Halo: device %@", up ? "connected" : "disconnected")
        connected = up
        if up {
            device.send(Robobloq.unstickBody)
            device.send([Robobloq.Cmd.deviceInfo])
            apply()
        } else {
            info = nil
            applyTask = Task { await engine.stop() }
        }
    }

    private func received(_ newInfo: DeviceInfo) {
        info = newInfo
        NSLog("Halo: %d LEDs, %d\", firmware %@", newInfo.ledCount, newInfo.sizeInches, newInfo.firmware)
        // Keep the layout's LED total in step with what the controller reports.
        if newInfo.ledCount > 0, settings.layout.total != newInfo.ledCount {
            autoLayout()
        }
    }

    // MARK: Applying state

    private func settingsChanged(from old: Settings) {
        save()
        guard connected else { return }
        let s = settings, o = old

        if whitePreviewActive {
            if s.picture.whiteBalance != o.picture.whiteBalance || s.brightness != o.brightness { sendWhitePreview() }
            return
        }
        guard !testPatternActive else { return }

        let captureMode = [.screen, .music, .auto].contains(s.mode)
        let needsApply = s.isOn != o.isOn || s.mode != o.mode
            || (s.mode == .color && (s.color != o.color || s.picture.whiteBalance != o.picture.whiteBalance))
            || (s.mode == .auto && !fullscreenDetected && (s.ambientColor != o.ambientColor || s.picture.whiteBalance != o.picture.whiteBalance))
            || (s.mode == .effect && s.effect != o.effect)
            || (s.mode == .pickup && s.pickupEffect != o.pickupEffect)
            || (s.mode == .music && s.musicStyle != o.musicStyle)
            || (captureMode && (s.displayID != o.displayID || s.picture.fps != o.picture.fps))
        if needsApply { apply(); return }

        // Small changes applied in place
        guard s.isOn else { return }
        if s.brightness != o.brightness {
            device.send(Robobloq.brightnessBody(percent: s.brightness))
        }
        if s.mode == .effect, s.speed != o.speed {
            device.send(Robobloq.speedBody(s.speed))
        }
        if s.mode == .pickup, s.pickupSensitivity != o.pickupSensitivity {
            device.send(Robobloq.speedBody(s.pickupSensitivity))
        }
        if engine.isRunning, s.layout != o.layout || s.picture != o.picture || s.musicTuning != o.musicTuning
            || s.musicPalette != o.musicPalette
            || s.paletteFrom != o.paletteFrom || s.paletteTo != o.paletteTo || s.partyStrobe != o.partyStrobe
            || s.spectrumMotion != o.spectrumMotion
            || s.lightDelayMs != o.lightDelayMs || s.autoSpeakerSync != o.autoSpeakerSync {
            refreshLightDelay()
            engine.update(engineConfig)
        }
    }

    func apply() {
        guard connected, !testPatternActive, !whitePreviewActive else { return }
        let s = settings
        outputDevice = Self.currentOutputDevice()
        effectiveLightDelayMs = computeLightDelay()
        let config = engineConfig
        let ambientOnly = s.mode == .auto && !fullscreenDetected
        applyTask?.cancel()
        applyTask = Task {
            // The controller can stall (e.g. after a half-written frame) and ignore frames until it gets this.
            device.send(Robobloq.unstickBody)
            if !s.isOn || asleep {
                await engine.stop()
                device.send([Robobloq.Cmd.turnOff])
                device.send(Robobloq.solidBody(.black, ledCount: ledCount))
                return
            }
            device.send(Robobloq.brightnessBody(percent: s.brightness))
            switch s.mode {
            case .color:
                await engine.stop()
                device.send(Robobloq.solidBody(wb(s.color), ledCount: ledCount))
            case .effect:
                await engine.stop()
                device.send(Robobloq.effectBody(s.effect))
                device.send(Robobloq.speedBody(s.speed))
            case .pickup:
                await engine.stop()
                device.send(Robobloq.pickupBody(s.pickupEffect))
                device.send(Robobloq.speedBody(s.pickupSensitivity))
            case .auto where ambientOnly:
                await engine.stop()
                device.send(Robobloq.solidBody(wb(s.ambientColor), ledCount: ledCount))
            case .screen, .music, .auto:
                await runEngine(config, displayID: effectiveDisplayID)
            }
        }
    }

    private func runEngine(_ config: EngineConfig, displayID: CGDirectDisplayID) async {
        do {
            try await engine.run(displayID: displayID, config: config)
            if Task.isCancelled { return }
            syncError = nil
            needsScreenPermission = false
        } catch {
            if Task.isCancelled { return }
            needsScreenPermission = !CGPreflightScreenCaptureAccess()
            syncError = needsScreenPermission
                ? "Halo needs Screen Recording permission to read your screen and audio."
                : error.localizedDescription
            NSLog("Halo: capture failed: %@", syncError ?? "")
        }
    }

    // MARK: Auto mode

    private func startAutoWatcher() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullscreen() }
        }
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
    }

    private func checkFullscreen() {
        guard settings.mode == .auto, settings.isOn else { return }
        let now = Self.hasFullscreenWindow(on: effectiveDisplayID)
        guard now != fullscreenDetected else { return }
        fullscreenDetected = now
        NSLog("Halo: auto mode → %@", now ? "fullscreen, syncing" : "ambient")
        apply()
    }

    /// True when another app has a normal-layer window covering the whole display
    /// (native fullscreen video, browser fullscreen, games).
    static func hasFullscreenWindow(on display: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(display)
        let me = ProcessInfo.processInfo.processIdentifier
        let ignored: Set<String> = ["Dock", "Window Server", "Finder", "Wallpaper", "Control Center", "Notification Center"]
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return windows.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  !ignored.contains(w[kCGWindowOwnerName as String] as? String ?? ""),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return false }
            return abs(rect.minX - bounds.minX) < 2 && abs(rect.minY - bounds.minY) < 2
                && abs(rect.width - bounds.width) < 2 && abs(rect.height - bounds.height) < 2
        }
    }

    // MARK: Sound output

    /// The default sound output, whether it's Bluetooth, and how late it plays sound according to
    /// Core Audio (device + stream latency + safety offset + buffer), in ms.
    static func currentOutputDevice() -> OutputDevice? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let cf = name?.takeRetainedValue() else { return nil }

        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyTransportType
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE

        func frames(_ selector: AudioObjectPropertySelector, _ object: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v = UInt32(0), s = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &a, 0, nil, &s, &v) == noErr ? v : 0
        }
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        addr.mSelector = kAudioDevicePropertyNominalSampleRate
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        var total = frames(kAudioDevicePropertyLatency, id, scope: kAudioObjectPropertyScopeOutput)
            + frames(kAudioDevicePropertySafetyOffset, id, scope: kAudioObjectPropertyScopeOutput)
            + frames(kAudioDevicePropertyBufferFrameSize, id, scope: kAudioObjectPropertyScopeOutput)
        var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
        var streamsSize = UInt32(0)
        if AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr, streamsSize > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            AudioObjectGetPropertyData(id, &streamsAddr, 0, nil, &streamsSize, &streams)
            if let first = streams.first { total += frames(kAudioStreamPropertyLatency, first, scope: kAudioObjectPropertyScopeGlobal) }
        }
        let latency = rate > 0 ? Double(total) / rate * 1000 : 0
        return OutputDevice(name: cf as String, bluetooth: bluetooth, latencyMs: latency)
    }

    /// How long to hold music frames back so they land with the sound from the speaker.
    private func computeLightDelay() -> Double {
        var d = settings.lightDelayMs
        if settings.autoSpeakerSync, let out = outputDevice {
            // Sound is heard `speaker` ms after it plays; Halo already sees it `audioLatencyMs` after,
            // and the USB write to the strip takes a few more ms.
            let speaker = settings.measuredLatency[out.name] ?? out.latencyMs
            d += speaker - max(0, audioLatencyMs ?? 0) - 8
        }
        return max(0, d)
    }

    // MARK: Speaker measurement

    @Published private(set) var calibrating = false
    @Published private(set) var calibrationMessage: String?

    /// Plays 8 beeps on the current speaker and times them with the built-in microphone.
    func measureSpeaker() {
        guard !calibrating else { return }
        guard let out = Self.currentOutputDevice() else { return }
        calibrating = true
        calibrationMessage = "Listening… (8 beeps)"
        Task {
            do {
                let r = try await SpeakerCalibrator.run()
                settings.measuredLatency[out.name] = r.latencyMs
                calibrationMessage = String(format: "%@: measured %.0f ms (±%.0f, %d/%d beeps). macOS reports %.0f ms.",
                                            out.name, r.latencyMs, r.spreadMs, r.heard, r.total, out.latencyMs)
            } catch {
                calibrationMessage = error.localizedDescription
            }
            UserDefaults.standard.set(calibrationMessage, forKey: "debug.lastCalibration")
            NSLog("Halo: %@", calibrationMessage ?? "")
            calibrating = false
            refreshLightDelay()
        }
    }

    private func refreshLightDelay() {
        let d = computeLightDelay()
        guard abs(d - effectiveLightDelayMs) > 3 else { return }
        effectiveLightDelayMs = d
        if engine.isRunning { engine.update(engineConfig) }
    }

    // MARK: Actions

    func requestScreenPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func autoLayout() {
        let aspect = displays.first(where: { $0.id == effectiveDisplayID })?.aspect ?? 16.0 / 9.0
        var l = LedLayout.auto(count: info?.ledCount ?? settings.layout.total, aspect: aspect)
        l.start = settings.layout.start
        l.depth = settings.layout.depth
        settings.layout = l
    }

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let f = screen.frame
            return DisplayChoice(id: id, name: screen.localizedName, aspect: f.width / max(f.height, 1))
        }
    }

    /// First 5 LEDs red, top corners green, last 5 blue — for checking layout and direction.
    func showTestPattern() {
        guard connected else { return }
        endHolds()
        testPatternActive = true
        holdTask = Task {
            await engine.stop()
            device.send(Robobloq.unstickBody)
            let L = settings.layout
            // Groups of LEDs rather than single dots, so they're easy to spot behind the monitor.
            var colors = [RGB](repeating: .black, count: L.total)
            func paint(_ range: Range<Int>, _ c: RGB) {
                for i in range where colors.indices.contains(i) { colors[i] = c }
            }
            for corner in [L.left, L.left + L.top].map({ $0 - 1 }) {
                paint(corner - 1 ..< corner + 2, RGB(r: 0, g: 255, b: 0))
            }
            paint(0 ..< 5, RGB(r: 255, g: 0, b: 0))
            paint(colors.count - 5 ..< colors.count, RGB(r: 0, g: 0, b: 255))
            device.send(Robobloq.brightnessBody(percent: max(settings.brightness, 60)))
            device.sendFrame(Robobloq.rangePayload(colors, maxRanges: colors.count))
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            endHolds()
        }
    }

    /// Shows white through the current white balance while it's being tuned.
    func toggleWhitePreview() {
        if whitePreviewActive { endHolds(); return }
        guard connected else { return }
        endHolds()
        whitePreviewActive = true
        holdTask = Task {
            await engine.stop()
            device.send(Robobloq.unstickBody)
            sendWhitePreview()
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            endHolds()
        }
    }

    private func sendWhitePreview() {
        device.send(Robobloq.brightnessBody(percent: settings.brightness))
        device.send(Robobloq.solidBody(wb(.white), ledCount: ledCount))
    }

    func endHolds() {
        holdTask?.cancel()
        let wasHolding = testPatternActive || whitePreviewActive
        testPatternActive = false
        whitePreviewActive = false
        if wasHolding { apply() }
    }

    func shutdown() {
        guard connected, settings.offOnQuit else { return }
        device.dropPendingFrame()
        device.sendNow([[Robobloq.Cmd.turnOff], Robobloq.solidBody(.black, ledCount: ledCount)])
    }

    // MARK: URL commands (Shortcuts, Terminal, launchers)

    /// halo://on, halo://mode/music, halo://color/ff8800, halo://brightness/40 … (see README)
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "halo" else { return }
        let command = (url.host ?? "").lowercased()
        let arg = url.pathComponents.dropFirst().first?.removingPercentEncoding?.lowercased() ?? ""
        var s = settings
        func number(_ range: ClosedRange<Double>) -> Double? {
            Double(arg).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        func index(_ names: [String]) -> Int? {
            if let i = Int(arg), names.indices.contains(i) { return i }
            return names.firstIndex { $0.lowercased() == arg }
        }

        switch command {
        case "on": s.isOn = true
        case "off": s.isOn = false
        case "toggle": s.isOn.toggle()
        case "mode":
            guard let m = LightMode(rawValue: arg) else { return reject(url) }
            s.mode = m; s.isOn = true
        case "color":
            guard let c = RGB(hex: arg) else { return reject(url) }
            s.color = c; s.mode = .color; s.isOn = true
        case "ambient":
            guard let c = RGB(hex: arg) else { return reject(url) }
            s.ambientColor = c
        case "brightness":
            switch arg {
            case "up": s.brightness = min(100, s.brightness + 10)
            case "down": s.brightness = max(1, s.brightness - 10)
            default:
                guard let v = number(1 ... 100) else { return reject(url) }
                s.brightness = v
            }
        case "effect":
            guard let i = index(Robobloq.effectNames) else { return reject(url) }
            s.effect = i; s.mode = .effect; s.isOn = true
        case "pickup":
            guard let i = index(Robobloq.pickupNames) else { return reject(url) }
            s.pickupEffect = i; s.mode = .pickup; s.isOn = true
        case "music":
            if !arg.isEmpty {
                guard let style = MusicStyle.allCases.first(where: { $0.rawValue == arg }) else { return reject(url) }
                s.musicStyle = style
            }
            s.mode = .music; s.isOn = true
        case "sensitivity":
            guard let v = number(0 ... 100) else { return reject(url) }
            s.tuning.sensitivity = v
        case "smoothness":
            guard let v = number(0 ... 100) else { return reject(url) }
            s.tuning.smoothness = v
        case "motion":
            guard let m = SpectrumMotion(rawValue: arg) else { return reject(url) }
            s.spectrumMotion = m
        case "palette":
            guard let p = MusicPalette(rawValue: arg) else { return reject(url) }
            s.musicPalette = p
        case "speed":
            guard let v = number(0 ... 100) else { return reject(url) }
            s.speed = v
        case "display":
            if arg.isEmpty || arg == "main" {
                s.displayID = nil
            } else if let d = displays.first(where: { $0.name.lowercased().contains(arg) }) {
                s.displayID = d.id
            } else { return reject(url) }
        case "blackbars":
            s.picture.blackBars = !["off", "0", "false"].contains(arg)
        case "settings":
            SettingsWindow.shared.show()
            return
        case "calibrate":
            measureSpeaker()
            return
        default:
            return reject(url)
        }
        settings = s
    }

    private func reject(_ url: URL) {
        NSLog("Halo: unknown command %@", url.absoluteString)
        NSSound.beep()
    }

    // MARK: Sleep / wake / displays

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(true) }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(false) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDisplays()
                if self.settings.isOn, self.usesScreenCapture {
                    Task { await self.engine.stop(); self.apply() }
                }
            }
        }
    }

    private func setAsleep(_ value: Bool) {
        guard settings.offOnSleep, asleep != value else { return }
        asleep = value
        apply()
    }
}
