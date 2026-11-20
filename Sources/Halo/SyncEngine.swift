import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Which corner LED 1 sits in, as seen from the front of the monitor.
enum StartCorner: String, Codable, CaseIterable, Identifiable {
    case bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String { self == .bottomLeft ? "Bottom-left" : "Bottom-right" }
}

/// LED counts per side as seen from the front. The strip runs up one side, across the top,
/// down the other side, then (optionally) along the bottom.
struct LedLayout: Codable, Equatable {
    var left = 18
    var top = 42
    var right = 18
    var bottom = 0
    var start: StartCorner = .bottomLeft
    /// How far into the picture each LED samples, as a fraction of width/height.
    var depth = 0.12

    var total: Int { left + top + right + bottom }

    /// Splits `count` LEDs over left/top/right in proportion to the display's edges.
    static func auto(count: Int, aspect: Double) -> LedLayout {
        var l = LedLayout()
        let side = Int((Double(count) / (2 + aspect)).rounded())
        l.left = side; l.right = side; l.top = max(0, count - 2 * side); l.bottom = 0
        return l
    }
}

struct WhiteBalance: Codable, Equatable {
    var r = 1.0
    var g = 1.0
    var b = 1.0

    func apply(_ c: RGB) -> RGB {
        func scale(_ v: UInt8, _ k: Double) -> UInt8 { UInt8(clamping: Int((Double(v) * k).rounded())) }
        return RGB(r: scale(c.r, r), g: scale(c.g, g), b: scale(c.b, b))
    }
}

struct PictureSettings: Codable, Equatable {
    var saturation = 1.25
    var gamma = 1.5
    /// 0 = instant, 0.9 = very smooth.
    var smoothing = 0.5
    var fps = 30
    /// Device-side LED ranges per frame. The vendor app uses 34; up to the LED count gives per-LED detail.
    var maxRanges = 78
    /// Sample from the edge of the picture instead of black bars (letterbox/pillarbox).
    var blackBars = true
    var whiteBalance = WhiteBalance()
}

enum MusicStyle: String, Codable, CaseIterable, Identifiable {
    case spectrum, pulse, party, screen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spectrum: "Spectrum"
        case .pulse: "Pulse"
        case .party: "Party"
        case .screen: "Screen"
        }
    }
}

enum SpectrumMotion: String, Codable, CaseIterable, Identifiable {
    case off, flow, beat, wave
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Colors used by the Spectrum and Pulse music styles, as gradient stops from bass to treble.
enum MusicPalette: String, Codable, CaseIterable, Identifiable {
    case rainbow, fire, ocean, neon, sunset, forest, ice, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func stops(customFrom: RGB, customTo: RGB) -> [RGB] {
        switch self {
        case .rainbow:
            [RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 140, b: 0), RGB(r: 255, g: 255, b: 0), RGB(r: 0, g: 255, b: 60),
             RGB(r: 0, g: 200, b: 255), RGB(r: 40, g: 0, b: 255), RGB(r: 180, g: 0, b: 255)]
        case .fire: [RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 70, b: 0), RGB(r: 255, g: 150, b: 0), RGB(r: 255, g: 230, b: 80)]
        case .ocean: [RGB(r: 0, g: 20, b: 255), RGB(r: 0, g: 120, b: 255), RGB(r: 0, g: 220, b: 255), RGB(r: 0, g: 255, b: 170)]
        case .neon: [RGB(r: 255, g: 0, b: 150), RGB(r: 170, g: 0, b: 255), RGB(r: 60, g: 40, b: 255), RGB(r: 0, g: 230, b: 255)]
        case .sunset: [RGB(r: 120, g: 0, b: 255), RGB(r: 255, g: 0, b: 140), RGB(r: 255, g: 60, b: 40), RGB(r: 255, g: 170, b: 0)]
        case .forest: [RGB(r: 0, g: 255, b: 30), RGB(r: 120, g: 255, b: 0), RGB(r: 0, g: 255, b: 150), RGB(r: 0, g: 180, b: 255)]
        case .ice: [RGB(r: 255, g: 255, b: 255), RGB(r: 150, g: 220, b: 255), RGB(r: 40, g: 120, b: 255)]
        case .custom: [customFrom, customTo]
        }
    }

    /// Color at position 0...1 along the gradient.
    static func sample(_ stops: [RGB], _ t: Double) -> (r: Double, g: Double, b: Double) {
        guard let first = stops.first else { return (0, 0, 0) }
        guard stops.count > 1 else { return (Double(first.r), Double(first.g), Double(first.b)) }
        let f = min(max(t, 0), 1) * Double(stops.count - 1)
        let i = min(Int(f), stops.count - 2), k = f - Double(i)
        let a = stops[i], b = stops[i + 1]
        func mix(_ x: UInt8, _ y: UInt8) -> Double { Double(x) + (Double(y) - Double(x)) * k }
        return (mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
    }
}

enum Render: Equatable {
    case screen
    case music(MusicStyle)

    var needsAudio: Bool { if case .music = self { true } else { false } }
}

struct EngineConfig: Equatable {
    var render: Render = .screen
    var layout = LedLayout()
    var picture = PictureSettings()
    var musicSensitivity = 50.0
    /// 0 = raw and twitchy, 100 = very soft fades.
    var musicSmoothness = 70.0
    var palette = MusicPalette.rainbow.stops(customFrom: .black, customTo: .black)
    /// Party style: short white flashes on big hits.
    var strobe = false
    /// Party style: 100 = club (hard hits), 0 = soft (crossfades, never dark).
    var partyIntensity = 100.0
    /// Spectrum style: how the palette moves along the strip over time.
    var spectrumMotion: SpectrumMotion = .beat
    /// Music: dim the side of the strip away from the louder stereo channel.
    var stereo = true
    /// Music: effects scale with the song's energy (calmer verses, bigger choruses).
    var songEnergy = true
    /// Music: a short whitish flash across the top middle on each snare or clap (no color change).
    var snareAccents = true
    /// Sync test: include Halo's own audio and flash the strip white on every detected kick.
    var syncTest = false
    /// Hold music frames back by this much so they line up with speakers that play late (Bluetooth).
    var lightDelayMs = 0.0
}

/// Captures the chosen display (and, for music, the Mac's audio output), turns it into LED colors
/// and streams frames to the device.
final class SyncEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct Rect: Equatable { var x0, x1, y0, y1: Int }

    private let device: RobobloqDevice
    private let q = DispatchQueue(label: "halo.sync", qos: .userInteractive)

    // Main actor only
    private var stream: SCStream?
    private var runningKey: String?
    var onStreamError: ((Error) -> Void)?

    // q only
    private var config = EngineConfig()
    private var zones: [Rect] = []
    private var zonesKey = ""
    private var frameSize = (w: 0, h: 0)
    private var content = Rect(x0: 0, x1: 0, y0: 0, y1: 0)
    private var darkColumns: [Int] = []
    private var darkRows: [Int] = []
    private var lastBarsDebug = Date.distantPast
    private var target: [Double] = []
    private var current: [Double] = []
    private var lastSent: [RGB] = []
    private var lastSendTime = Date.distantPast
    private var lastUnstick = Date.distantPast
    private var timer: DispatchSourceTimer?
    private let audio = AudioAnalyzer()
    private var hue = 0.0
    private var musicFade: [Double] = []
    private var musicLit: [Bool] = []
    // Party style state (q only)
    // Spectrum color motion state (q only)
    private var spectrumOffset = 0.0
    private var spectrumTarget = 0.0
    private var spectrumSeenBeat = 0
    private var spectrumBeats = 0
    private var spectrumApplied = 0.0
    private var ledXKey: LedLayout?
    // Debug frame recorder (q only)
    private var recordUntil: Date?
    private var recordLines: [String] = []
    private var recordStart = Date()
    private var ledXCache: [Double] = []
    private var topWKey: LedLayout?
    private var topWCache: [Double] = []
    private var spectrumHistory: [Double] = []
    private var partySeenBeat = 0
    private var partyBeats = 0
    private var partyPattern = 0
    private var partyColor = 0
    private var partyPrevColor = 0
    private var partyBeatTime = Date.distantPast
    private var partyPhase = 0.0
    private var strobeFrames = 0

    /// Called on the main thread about once a second with how late audio arrives from macOS (ms).
    var onAudioLatency: ((Double) -> Void)?
    private var lastStats = Date.distantPast

    init(device: RobobloqDevice) {
        self.device = device
        super.init()
        // Render the moment a beat is found instead of waiting for the next frame tick.
        audio.onBeat = { [weak self] in self?.tick() }
    }

    var isRunning: Bool { stream != nil }

    /// Starts capture, or just updates settings when the running stream already fits.
    @MainActor
    func run(displayID: CGDirectDisplayID?, config: EngineConfig) async throws {
        let key = "\(displayID ?? 0)-\(config.picture.fps)-\(config.render.needsAudio)-\(config.syncTest)"
        if stream != nil, key == runningKey {
            update(config)
            return
        }
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else { throw NSError(domain: "Halo", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"]) }

        let fps = max(5, config.picture.fps)
        let cfg = SCStreamConfiguration()
        let aspect = Double(display.width) / Double(max(display.height, 1))
        cfg.height = 90
        cfg.width = max(16, Int((90 * aspect).rounded()))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = false
        cfg.queueDepth = 3
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        if config.render.needsAudio {
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = !config.syncTest
            cfg.sampleRate = 48000
            cfg.channelCount = 2
        }

        q.sync {
            self.config = config
            self.zonesKey = ""
            self.target = []
            self.current = []
            self.lastSent = []
            self.audio.reset()
            self.audio.sensitivity = config.musicSensitivity
        }

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if config.render.needsAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        }
        try await s.startCapture()
        stream = s
        runningKey = key
        startTimer(fps: fps)
    }

    @MainActor
    func stop() async {
        guard let s = stream else { return }
        stream = nil
        runningKey = nil
        q.sync { timer?.cancel(); timer = nil }
        device.dropPendingFrame()
        try? await s.stopCapture()
    }

    /// Live-update settings that don't need a new capture stream.
    func update(_ config: EngineConfig) {
        q.async {
            if self.config.layout != config.layout { self.zonesKey = ""; self.target = []; self.current = [] }
            if !config.picture.blackBars { self.darkColumns = []; self.darkRows = [] }
            self.config = config
            self.audio.sensitivity = config.musicSensitivity
        }
    }

    private func startTimer(fps: Int) {
        q.sync {
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    // MARK: SCStream

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stream = nil
            self.runningKey = nil
            self.q.async { self.timer?.cancel(); self.timer = nil }
            self.onStreamError?(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        if type == .audio {
            audio.process(sb)
            return
        }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer
        else { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)

        if frameSize != (w, h) {
            frameSize = (w, h)
            content = Rect(x0: 0, x1: w, y0: 0, y1: h)
            darkColumns = []
            darkRows = []
        }
        if config.picture.blackBars {
            trackContent(base: base, bpr: bpr, w: w, h: h)
        } else {
            content = Rect(x0: 0, x1: w, y0: 0, y1: h)
        }

        let key = "\(content)-\(config.layout.total)"
        if key != zonesKey {
            zones = Self.makeZones(config.layout, in: content)
            zonesKey = key
        }

        var t = [Double](repeating: 0, count: zones.count * 3)
        for (i, z) in zones.enumerated() {
            var r = 0, g = 0, b = 0
            for y in z.y0 ..< z.y1 {
                var p = base + y * bpr + z.x0 * 4
                for _ in z.x0 ..< z.x1 {
                    b += Int(p[0]); g += Int(p[1]); r += Int(p[2])
                    p += 4
                }
            }
            let n = Double(max(1, (z.x1 - z.x0) * (z.y1 - z.y0)))
            t[i * 3] = Double(r) / n
            t[i * 3 + 1] = Double(g) / n
            t[i * 3 + 2] = Double(b) / n
        }
        target = t
        if current.count != t.count { current = t }
    }

    // MARK: Black bars

    /// Finds the picture inside letterbox/pillarbox bars. Bars are dark in *every* frame, while dark parts of
    /// the video light up now and then, so each edge column/row counts how many frames in a row it has stayed
    /// dark; only edges dark for over a second count as bars. Any light in a column ends its bar status at once.
    private func trackContent(base: UnsafeMutablePointer<UInt8>, bpr: Int, w: Int, h: Int) {
        // Bars are pure black; dark parts of a picture almost never are, so the bar threshold is strict.
        let threshold: UInt8 = 12
        func lit(_ p: UnsafeMutablePointer<UInt8>) -> Bool { max(p[0], p[1], p[2]) > threshold }
        // Only look at the middle of the frame: video players draw their title (top) and controls with a
        // dark gradient (bottom) across the full screen width, right over the black bars.
        let rowsFrom = h * 15 / 100, rowsTo = h - h * 22 / 100
        let colsFrom = w * 10 / 100, colsTo = w - w * 10 / 100
        if darkColumns.count != w { darkColumns = [Int](repeating: 0, count: w) }
        if darkRows.count != h { darkRows = [Int](repeating: 0, count: h) }
        // Only edge regions can be bars, so only those are scanned.
        let maxX = w * 30 / 100, maxY = h * 25 / 100
        for x in Array(0 ..< maxX) + Array((w - maxX) ..< w) {
            let on = stride(from: rowsFrom, to: rowsTo, by: 2).contains { lit(base + $0 * bpr + x * 4) }
            darkColumns[x] = on ? 0 : darkColumns[x] + 1
        }
        for y in Array(0 ..< maxY) + Array((h - maxY) ..< h) {
            let on = stride(from: colsFrom, to: colsTo, by: 2).contains { lit(base + y * bpr + $0 * 4) }
            darkRows[y] = on ? 0 : darkRows[y] + 1
        }

        let needed = max(10, config.picture.fps)   // ~1 s of frames
        var l = 0
        while l < maxX, darkColumns[l] >= needed { l += 1 }
        var r = 0
        while r < maxX, darkColumns[w - 1 - r] >= needed { r += 1 }
        var t = 0
        while t < maxY, darkRows[t] >= needed { t += 1 }
        var b = 0
        while b < maxY, darkRows[h - 1 - b] >= needed { b += 1 }

        // Players centre the picture, so bars always come in equal pairs. If one side reads wider, the extra
        // is dark picture, so the narrower side is the true bar width. Real video gives 3–30 % per side
        // (16:9 on 21:9 ≈ 13 %, 4:3 on 21:9 ≈ 22 %) and 3–25 % top/bottom; a run that hits the limit
        // means a dark scene, not bars.
        var found = Rect(x0: 0, x1: w, y0: 0, y1: h)
        let minX = max(2, w * 3 / 100), minY = max(2, h * 3 / 100)
        let side = min(l, r), cap = min(t, b)
        if side >= minX, max(l, r) < maxX { found.x0 = side; found.x1 = w - side }
        if cap >= minY, max(t, b) < maxY { found.y0 = cap; found.y1 = h - cap }
        content = found

        // Diagnostics, about once a second: `defaults read local.halo.backlight debug.blackBars`
        let now = Date()
        if now.timeIntervalSince(lastBarsDebug) > 1 {
            lastBarsDebug = now
            let line = "frame \(w)x\(h) bars L\(l) R\(r) T\(t) B\(b) | using x\(content.x0)-\(content.x1) y\(content.y0)-\(content.y1)"
            UserDefaults.standard.set(line, forKey: "debug.blackBars")
        }
    }

    // MARK: Output

    private func tick() {
        let colors: [RGB]
        switch config.render {
        case .screen:
            guard let c = screenColors() else { return }
            colors = c
        case .music(let style):
            audio.decay()
            if config.syncTest {
                // Sharp white blip per kick, no fades, so its timing against the sound is easy to judge.
                let v = pow(audio.beat, 3)
                colors = [RGB](repeating: RGB(r: UInt8(255 * v), g: UInt8(255 * v), b: UInt8(255 * v)),
                               count: max(1, config.layout.total))
            } else {
                var raw = musicColors(style)
                if config.snareAccents, style != .screen { raw = applySnare(raw, style: style) }
                if config.stereo { raw = applyStereo(raw) }
                colors = fadeMusic(raw, punch: style == .party ? partyIntensity : 0)
            }
            if recordUntil != nil { recordFrame(colors) }
            let now = Date()
            if now.timeIntervalSince(lastStats) > 1 {
                lastStats = now
                let ms = audio.captureLatencyMs
                DispatchQueue.main.async { [weak self] in self?.onAudioLatency?(ms) }
            }
            let delay = config.lightDelayMs
            if delay > 0 {
                let out = colors.map(config.picture.whiteBalance.apply)
                q.asyncAfter(deadline: .now() + delay / 1000) { [weak self] in self?.send(out) }
                return
            }
        }
        send(colors.map(config.picture.whiteBalance.apply))
    }

    private func screenColors(scale: Double = 1) -> [RGB]? {
        guard !target.isEmpty, current.count == target.count else { return nil }
        let a = min(max(config.picture.smoothing, 0), 0.95)
        for i in current.indices { current[i] = current[i] * a + target[i] * (1 - a) }
        var colors: [RGB] = []
        colors.reserveCapacity(current.count / 3)
        for i in stride(from: 0, to: current.count, by: 3) {
            colors.append(grade(current[i] * scale, current[i + 1] * scale, current[i + 2] * scale))
        }
        return colors
    }

    private func musicColors(_ style: MusicStyle) -> [RGB] {
        let n = max(1, config.layout.total)
        switch style {
        case .spectrum:
            // Bass at LED 1 (bottom-left) through treble at the last LED, colored along the palette,
            // which can move along the strip over time (see `advanceSpectrumMotion`).
            advanceSpectrumMotion()
            let bands = audio.bands
            let stops = config.palette
            // Beat/Wave: every kick lifts the whole strip at once (no color flash); a deep, hard kick then
            // blooms further over the next ~2 frames as its strength comes in. Bigger in a chorus.
            let lift = config.spectrumMotion == .beat || config.spectrumMotion == .wave
                ? min(0.9, audio.beat * (0.4 + 0.45 * audio.beatStrength * audio.beatStrength) * energyScale) : 0
            // Wave: the bass end shows the newest colors and the treble end what the bass end showed ~0.6 s ago,
            // so every kick travels along the strip.
            let travel = config.spectrumMotion == .wave ? Double(max(5, config.picture.fps)) * 0.6 : 0
            return (0 ..< n).map { i in
                let p = n > 1 ? Double(i) / Double(n - 1) : 0
                let offset = pastSpectrumOffset(framesAgo: p * travel)
                let f = p * Double(bands.count - 1)
                let lo = Int(f), hi = min(lo + 1, bands.count - 1)
                let raw = pow(bands[lo] + (bands[hi] - bands[lo]) * (f - Double(lo)), 1.4)
                let level = raw + (1 - raw) * lift
                // Mirrored wrap (period 2): equals p when offset is 0 and never jumps from the last color to the first.
                let y = ((p + offset) / 2).truncatingRemainder(dividingBy: 1)
                let c = MusicPalette.sample(stops, 1 - abs(1 - 2 * y))
                return scaled(c, level)
            }
        case .pulse:
            // Whole strip breathes with the music; the color moves along the palette on every beat.
            hue = (hue + 0.0008).truncatingRemainder(dividingBy: 1)
            let t = hue + Double(audio.beatCount % 8) / 8
            let v = 0.06 + 0.94 * max(min(1, audio.beat * energyScale), audio.loudness * 0.75)
            let stops = config.palette
            return (0 ..< n).map { i in
                // Triangle wave so the color sweeps back and forth instead of jumping from the last stop to the first.
                let x = (t + Double(i) / Double(n) * 0.15).truncatingRemainder(dividingBy: 1)
                return scaled(MusicPalette.sample(stops, 1 - abs(1 - 2 * x)), v)
            }
        case .party:
            return partyColors(n)
        case .screen:
            let level = 0.2 + 0.8 * max(audio.beat, audio.loudness)
            return screenColors(scale: level) ?? [RGB](repeating: .black, count: n)
        }
    }

    /// Moves the Spectrum palette along the strip. Beat and Wave are driven by the bass: the palette flows
    /// while bass plays (faster the heavier it is, still in quiet parts) and jumps on every kick by how hard
    /// it hits (a soft kick barely, a heavy one by half the palette; 1.4× on every 4th beat), gliding in
    /// over ~2 frames.
    private func advanceSpectrumMotion() {
        switch config.spectrumMotion {
        case .off:
            spectrumTarget = 0
        case .flow:
            spectrumTarget += 0.0015
        case .beat, .wave:
            spectrumTarget += (0.0004 + 0.012 * audio.bass * audio.bass) * energyScale
            if audio.beatCount != spectrumSeenBeat {
                spectrumSeenBeat = audio.beatCount
                spectrumBeats += 1
                spectrumApplied = 0
            }
            // Strength keeps rising for the kick's first ~60 ms, so add only what it grew since last frame.
            let s = audio.beatStrength
            if s > spectrumApplied {
                let accent = spectrumBeats % 4 == 0 ? 1.4 : 1
                spectrumTarget += 0.5 * (s * s - spectrumApplied * spectrumApplied) * accent * energyScale
                spectrumApplied = s
            }
        }
        spectrumOffset += (spectrumTarget - spectrumOffset) * 0.5
        spectrumHistory.append(spectrumOffset)
        if spectrumHistory.count > 90 { spectrumHistory.removeFirst(spectrumHistory.count - 90) }
        // The mirrored wrap repeats every 2, so keep the numbers small without a visible change.
        if spectrumOffset > 4, spectrumTarget > 4 {
            spectrumOffset -= 2; spectrumTarget -= 2
            for i in spectrumHistory.indices { spectrumHistory[i] -= 2 }
        }
    }

    /// The palette offset `framesAgo` frames back (interpolated), for Wave's travel along the strip.
    private func pastSpectrumOffset(framesAgo: Double) -> Double {
        guard framesAgo > 0, spectrumHistory.count > 1 else { return spectrumOffset }
        let last = spectrumHistory.count - 1
        let x = Double(last) - min(framesAgo, Double(last))
        let lo = Int(x), hi = min(lo + 1, last)
        return spectrumHistory[lo] + (spectrumHistory[hi] - spectrumHistory[lo]) * (x - Double(lo))
    }

    /// Club-style: every beat lands as a hard hit in a new color, and the pattern changes every 16 beats.
    /// Intensity (0...1) runs from Club (hard cuts, dark between hits) down to Soft: colors crossfade on
    /// each beat, the strip never drops to dark, and kicks only lift the brightness a little.
    private func partyColors(_ n: Int) -> [RGB] {
        let now = Date()
        let intensity = partyIntensity
        if audio.beatCount != partySeenBeat {
            partySeenBeat = audio.beatCount
            partyBeats += 1
            partyPrevColor = partyColor
            partyColor += 1
            partyBeatTime = now
            if partyBeats % 16 == 0 { partyPattern = (partyPattern + 1) % 4 }
            // Strobe on the downbeat of each bar when the track is loud.
            if config.strobe, intensity > 0.6, partyBeats % 4 == 0, audio.loudness > 0.7 { strobeFrames = 2 }
        }
        if strobeFrames > 0 {
            strobeFrames -= 1
            return [RGB](repeating: .white, count: n)
        }

        let stops = config.palette
        // Step through the palette so neighbouring beats get clearly different colors.
        func color(_ k: Int) -> (r: Double, g: Double, b: Double) {
            let x = (Double(k) * 0.381966).truncatingRemainder(dividingBy: 1)
            return MusicPalette.sample(stops, stops.count == 2 ? Double(k % 2) : x)
        }
        // At intensity 100 this is the original Party exactly: full hits, a low glow that follows loudness,
        // hard color cuts. Lower intensity raises the glow floor and softens hits and cuts.
        let hit = audio.beat * (0.3 + 0.7 * intensity)
        let soft = 1 - intensity
        let glow = max(0.04 + 0.18 * audio.loudness, 0.5 * soft * (0.7 + 0.3 * audio.bass))
        let lit = max(hit, glow)
        let dim = 0.5 + 0.5 * soft                              // how bright the unlit parts of a pattern stay
        let since = now.timeIntervalSince(partyBeatTime)
        // New beat color: a hard cut at full intensity, up to a ~0.5 s crossfade at the softest.
        let fadeTime = 0.5 * pow(soft, 1.5)
        let blend = fadeTime < 0.01 ? 1 : min(1, since / fadeTime)
        let prev = color(partyPrevColor), next = color(partyColor)
        let e = blend * blend * (3 - 2 * blend)
        let c = (r: prev.r + (next.r - prev.r) * e, g: prev.g + (next.g - prev.g) * e, b: prev.b + (next.b - prev.b) * e)
        partyPhase = (partyPhase + 0.008 + audio.loudness * 0.025).truncatingRemainder(dividingBy: 1)

        return (0 ..< n).map { i in
            let p = n > 1 ? Double(i) / Double(n - 1) : 0
            switch partyPattern {
            case 0:  // Full flash
                return scaled(c, lit)
            case 1:  // Left and right halves take turns
                let litLeft = partyBeats % 2 == 0
                let onLit = (p < 0.5) == litLeft
                return onLit ? scaled(c, lit) : scaled(prev, glow * (0.6 + 0.4 * soft))
            case 2:  // Four segments chasing around the strip
                let x = (p * 4 - partyPhase * 4 + Double(partyBeats) * 0.25).truncatingRemainder(dividingBy: 1)
                let inSegment = (x < 0 ? x + 1 : x) < 0.35
                return inSegment ? scaled(c, max(0.55, lit)) : scaled(prev, glow * dim)
            default: // Burst expanding from the top centre on each beat
                let radius = since * 1.6
                let d = abs(p - 0.5)
                let ring = d < radius && d > radius - 0.18
                return ring ? scaled(c, max(0.4, 1 - since * 1.2, glow)) : scaled(prev, glow * dim)
            }
        }
    }

    /// Writes every music frame (audio features + LED colors) for `seconds` to
    /// ~/Library/Caches/Halo-build/frames.csv, for diagnosing how the lights respond.
    func record(seconds: Double) {
        q.async {
            self.recordStart = Date()
            self.recordUntil = Date().addingTimeInterval(seconds)
            self.recordLines = ["t,beatCount,strength,bass,balance,beat,offset,energy,snareCount,snareStats,colors"]
        }
    }

    private func recordFrame(_ colors: [RGB]) {
        let now = Date()
        let rgb = colors.map { "\($0.r) \($0.g) \($0.b)" }.joined(separator: ";")
        recordLines.append(String(format: "%.4f,%d,%.3f,%.3f,%.3f,%.3f,%.4f,", now.timeIntervalSince(recordStart),
                                  audio.beatCount, audio.beatStrength, audio.bass, audio.balance, audio.beat,
                                  spectrumOffset) + String(format: "%.3f,%d,%.2f/%.2f/%.3f,", audio.energy, audio.snareCount, audio.lastSnareStats.peak,
                                                audio.lastSnareStats.hat, audio.lastSnareStats.kick) + rgb)
        if let until = recordUntil, now >= until {
            recordUntil = nil
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Halo-build")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? recordLines.joined(separator: "\n").write(to: dir.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
            recordLines = []
        }
    }

    /// How big the beat effects are right now: 0.55 in the calmest part of the song, 1.45 in its biggest.
    private var energyScale: Double { config.songEnergy ? 0.55 + 0.9 * audio.energy : 1 }

    /// Party intensity as set. Song energy doesn't change it: at 100, Party stays the original club look.
    private var partyIntensity: Double { min(max(config.partyIntensity / 100, 0), 1) }

    /// How much each LED takes part in snare accents: 1 at the top centre, fading to 0 by ~35 % either side
    /// along the top; 0 on the sides and bottom.
    private func topWeights(_ layout: LedLayout) -> [Double] {
        if topWKey == layout, topWCache.count == layout.total { return topWCache }
        var L = layout
        if L.start == .bottomRight { swap(&L.left, &L.right) }
        var w = [Double](repeating: 0, count: L.total)
        for k in 0 ..< L.top {
            let x = (Double(k) + 0.5) / Double(L.top)
            w[L.left + k] = max(0, 1 - abs(x - 0.5) / 0.35)
        }
        topWKey = layout; topWCache = w
        return w
    }

    /// Snare/clap: the top middle flashes toward white for ~0.1 s. It doesn't touch colors or the kick's
    /// effects, so the eye reads kick ("boom") and snare ("tak") as different things, like the ear does.
    private func applySnare(_ colors: [RGB], style: MusicStyle) -> [RGB] {
        guard audio.snare > 0.02 else { return colors }
        let ws = topWeights(config.layout)
        guard ws.count == colors.count else { return colors }
        let styleScale = style == .party ? 0.4 + 0.6 * partyIntensity : energyScale
        let amount = min(1, audio.snare * 0.6 * styleScale)
        return zip(colors, ws).map { c, w in
            let a = amount * w
            guard a > 0.005 else { return c }
            func up(_ v: UInt8) -> UInt8 { UInt8(min(255, Double(v) + (255 - Double(v)) * a)) }
            return RGB(r: up(c.r), g: up(c.g), b: up(c.b))
        }
    }

    /// Horizontal position of each LED as seen from the front: 0 = left edge, 1 = right edge.
    private func ledX(_ layout: LedLayout) -> [Double] {
        if ledXKey == layout, ledXCache.count == layout.total { return ledXCache }
        var L = layout
        if L.start == .bottomRight { swap(&L.left, &L.right) }
        var x: [Double] = []
        x += [Double](repeating: 0, count: L.left)
        x += (0 ..< L.top).map { (Double($0) + 0.5) / Double(L.top) }
        x += [Double](repeating: 1, count: L.right)
        x += (0 ..< L.bottom).map { 1 - (Double($0) + 0.5) / Double(L.bottom) }
        if L.start == .bottomRight { x = x.map { 1 - $0 } }
        ledXKey = layout; ledXCache = x
        return x
    }

    /// Follows the stereo image: the side away from the louder channel dims (up to 85 % when one channel
    /// is 12 dB louder), the dominant side and the middle keep full brightness.
    private func applyStereo(_ colors: [RGB]) -> [RGB] {
        // Ignore the small imbalance most mixes have; follow clear left/right leaning.
        let raw = audio.balance
        let b = raw < 0 ? min(0, raw + 0.1) / 0.9 : max(0, raw - 0.1) / 0.9
        guard abs(b) > 0.01 else { return colors }
        let xs = ledX(config.layout)
        guard xs.count == colors.count else { return colors }
        return zip(colors, xs).map { c, x in
            let away = max(0, -b * (2 * x - 1))   // 0 on the loud side and in the middle, up to |b| on the far side
            let g = 1 - 0.85 * away
            return RGB(r: UInt8(Double(c.r) * g), g: UInt8(Double(c.g) * g), b: UInt8(Double(c.b) * g))
        }
    }

    /// Rises fairly quickly (so beats still land) but falls slowly, which removes the flicker
    /// that raw audio levels cause. Works per LED and per channel. A dark LED only turns on once it
    /// would be clearly visible, so near-black LEDs don't sparkle on and off.
    private func fadeMusic(_ colors: [RGB], punch: Double = 0) -> [RGB] {
        let s = min(max(config.musicSmoothness, 0), 100) / 100
        // Full-intensity Party hits must land instantly; smoothness then only shapes how fast they fall away.
        // `punch` blends from the normal soft fades (0) to that (1).
        let attack = punch + (1 - punch) * (0.9 - 0.6 * s)   // share of the gap closed per frame when getting brighter
        let release = punch * (0.55 - 0.35 * s) + (1 - punch) * (0.4 - 0.34 * s)   // ... and when getting darker
        if musicFade.count != colors.count * 3 {
            musicFade = colors.flatMap { [Double($0.r), Double($0.g), Double($0.b)] }
            musicLit = [Bool](repeating: true, count: colors.count)
        }
        var out: [RGB] = []
        out.reserveCapacity(colors.count)
        for (i, c) in colors.enumerated() {
            var channels = [Double(c.r), Double(c.g), Double(c.b)]
            for k in 0 ..< 3 {
                let j = i * 3 + k
                let old = musicFade[j], new = channels[k]
                // Big rises (a kick) land at once whatever the smoothness; only small wobbles are smoothed,
                // so high smoothness removes flicker without making beats late.
                let rise = new - old
                let a = rise > 0 ? attack + (1 - attack) * min(1, rise / 50) : release
                musicFade[j] = old + rise * a
                channels[k] = musicFade[j]
            }
            let peak = channels.max() ?? 0
            if musicLit[i] ? peak < 3 : peak >= 8 { musicLit[i].toggle() }
            guard musicLit[i] else { out.append(.black); continue }
            func byte(_ v: Double) -> UInt8 { v < 2 ? 0 : UInt8(min(255, v.rounded())) }
            out.append(RGB(r: byte(channels[0]), g: byte(channels[1]), b: byte(channels[2])))
        }
        return out
    }

    private func send(_ colors: [RGB]) {
        let changed = colors.count != lastSent.count || zip(colors, lastSent).contains {
            abs(Int($0.r) - Int($1.r)) > 1 || abs(Int($0.g) - Int($1.g)) > 1 || abs(Int($0.b) - Int($1.b)) > 1
        }
        let now = Date()
        // Periodic unstick so a stalled controller recovers by itself mid-stream.
        if now.timeIntervalSince(lastUnstick) > 3 {
            lastUnstick = now
            device.send(Robobloq.unstickBody)
        }
        guard changed || now.timeIntervalSince(lastSendTime) > 1 else { return }
        lastSent = colors
        lastSendTime = now
        device.sendFrame(Robobloq.rangePayload(colors, maxRanges: config.picture.maxRanges))
    }

    /// Saturation boost around the pixel's luma, then gamma so dark scenes stay dark on the wall.
    private func grade(_ r: Double, _ g: Double, _ b: Double) -> RGB {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let s = config.picture.saturation
        func out(_ c: Double) -> UInt8 {
            let v = min(max(luma + (c - luma) * s, 0), 255) / 255
            let o = pow(v, config.picture.gamma) * 255
            return o < 2 ? 0 : UInt8(min(255, o.rounded()))
        }
        return RGB(r: out(r), g: out(g), b: out(b))
    }

    private func scaled(_ c: (r: Double, g: Double, b: Double), _ v: Double) -> RGB {
        func byte(_ x: Double) -> UInt8 { UInt8(min(255, max(0, (x * v).rounded()))) }
        return RGB(r: byte(c.r), g: byte(c.g), b: byte(c.b))
    }

    /// Zones in strip order inside `area`. Base order starts bottom-left going clockwise (viewed from the front):
    /// left side bottom→top, top left→right, right side top→bottom, bottom right→left.
    private static func makeZones(_ layout: LedLayout, in area: Rect) -> [Rect] {
        var L = layout
        // Built bottom-left-first, then mirrored, so the side counts must be swapped too.
        if L.start == .bottomRight { swap(&L.left, &L.right) }
        let w = max(1, area.x1 - area.x0), h = max(1, area.y1 - area.y0)
        let dx = max(1, Int(Double(w) * L.depth)), dy = max(1, Int(Double(h) * L.depth))
        func span(_ k: Int, _ n: Int, _ len: Int) -> (Int, Int) {
            let a = k * len / n, b = (k + 1) * len / n
            return (a, max(b, a + 1))
        }
        var z: [Rect] = []
        for k in 0 ..< L.left {               // bottom → top
            let (a, b) = span(k, L.left, h)
            z.append(Rect(x0: 0, x1: dx, y0: h - b, y1: h - a))
        }
        for k in 0 ..< L.top {                // left → right
            let (a, b) = span(k, L.top, w)
            z.append(Rect(x0: a, x1: b, y0: 0, y1: dy))
        }
        for k in 0 ..< L.right {              // top → bottom
            let (a, b) = span(k, L.right, h)
            z.append(Rect(x0: w - dx, x1: w, y0: a, y1: b))
        }
        for k in 0 ..< L.bottom {             // right → left
            let (a, b) = span(k, L.bottom, w)
            z.append(Rect(x0: w - b, x1: w - a, y0: h - dy, y1: h))
        }
        if L.start == .bottomRight {
            // Mirror horizontally: same path, starting bottom-right going counter-clockwise.
            z = z.map { Rect(x0: w - $0.x1, x1: w - $0.x0, y0: $0.y0, y1: $0.y1) }
        }
        // Offset into the picture area
        return z.map { Rect(x0: $0.x0 + area.x0, x1: $0.x1 + area.x0, y0: $0.y0 + area.y0, y1: $0.y1 + area.y0) }
    }
}
