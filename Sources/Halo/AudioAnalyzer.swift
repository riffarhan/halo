import Accelerate
import CoreMedia
import Foundation

/// Turns the Mac's audio output (delivered by ScreenCaptureKit) into band levels, loudness and beats.
/// Not thread-safe: call everything from one queue.
final class AudioAnalyzer {
    static let bandCount = 24

    /// 0...1 per band, low to high frequency, smoothed (fast attack, slower release).
    private(set) var bands = [Double](repeating: 0, count: bandCount)
    /// 0...1 overall loudness, smoothed.
    private(set) var loudness = 0.0
    /// 1 on a detected bass beat, decaying towards 0 every `decay()` call.
    private(set) var beat = 0.0
    /// Increments on every beat; used to step colors.
    private(set) var beatCount = 0
    /// 0...1 how hard the latest kick hit compared with the loudest recent ones. Starts at the kick's onset
    /// and keeps rising for its first ~60 ms, until the kick peaks.
    private(set) var beatStrength = 0.0
    /// 0...1 continuous bass level (the kick band relative to its recent peak): fast attack, ~0.2 s release.
    private(set) var bass = 0.0
    /// -1 (all left) ... 0 (centered) ... +1 (all right): the left/right level difference, ±12 dB = ±1, smoothed.
    private(set) var balance = 0.0

    /// Higher = reacts to quieter sound. 0...100.
    var sensitivity = 50.0

    /// Called on the analysis queue the moment a beat is detected.
    var onBeat: (() -> Void)?
    /// How late macOS hands over audio, in ms (smoothed): now − end of the buffer.
    private(set) var captureLatencyMs = 0.0

    // 1024 samples ≈ 21 ms at 48 kHz: half the wait of a 2048 window, still fine for 24 bands.
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let fft: FFTSetup
    private let window: [Float]
    private var ring: [Float] = []
    private var bandPeak = [Double](repeating: -40, count: bandCount)
    private var loudPeak = -40.0
    /// Seconds of audio since the last kick (counted in samples, so timing doesn't depend on delivery).
    private var sinceBeat = 10.0
    private var lp1: Float = 0, lp2: Float = 0
    private var bassSlow = 0.0, bassPeak = 0.0, bassPrev = 0.0
    /// Loudest recent kick level, halving over ~20 s: what kick strength is measured against.
    private var kickRef = 0.0
    /// Kick-band level of the last 8 blocks (~40 ms): a kick has to rise clearly above their minimum.
    private var bassRecent = [Double](repeating: 0, count: 8)
    private var bassRecentIndex = 0
    /// Peak level of the last kick. A new kick must beat 85 % of it as it fades (e^-t/0.5 s), so the swells of
    /// one bass note don't count as new kicks, while a kick as hard 0.25 s later, or half as hard 0.5 s
    /// later, still does.
    private var lastBeatPeak = 0.0
    /// Sum of squares and sample counts of the last 4 blocks (~21 ms): one full cycle of a 50 Hz kick,
    /// so the level doesn't swing with the wave's phase the way a single 5 ms block does.
    private var blockSums = [Float](repeating: 0, count: 4)
    private var blockCounts = [Int](repeating: 0, count: 4)
    private var blockIndex = 0

    init() {
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        ring.reserveCapacity(n * 2)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func reset() {
        bands = [Double](repeating: 0, count: Self.bandCount)
        loudness = 0; beat = 0; beatStrength = 0; bass = 0; balance = 0; kickRef = 0; lastBeatPeak = 0
        blockSums = [Float](repeating: 0, count: 4); blockCounts = [Int](repeating: 0, count: 4)
        bassRecent = [Double](repeating: 0, count: 8); ring.removeAll(keepingCapacity: true)
    }

    /// Call once per output frame.
    func decay() {
        beat *= 0.86
    }

    func process(_ sb: CMSampleBuffer) {
        guard let fmt = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32
        else { return }
        let frames = sb.numSamples
        guard frames > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        var energyL: Float = 0, energyR: Float = 0, stereo = false
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        try? sb.withAudioBufferList { list, _ in
            if nonInterleaved {
                var channels = 0
                for buf in list {
                    guard let d = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let count = min(frames, Int(buf.mDataByteSize) / 4)
                    for i in 0 ..< count { mono[i] += d[i] }
                    if channels < 2 {
                        let e = vDSP.sumOfSquares(UnsafeBufferPointer(start: d, count: count))
                        if channels == 0 { energyL = e } else { energyR = e; stereo = true }
                    }
                    channels += 1
                }
                if channels > 1 { vDSP.multiply(1 / Float(channels), mono, result: &mono) }
            } else if let d = list.first?.mData?.assumingMemoryBound(to: Float.self) {
                let ch = max(1, Int(asbd.mChannelsPerFrame))
                for i in 0 ..< frames {
                    var s: Float = 0
                    for c in 0 ..< ch { s += d[i * ch + c] }
                    mono[i] = s / Float(ch)
                    if ch >= 2 { energyL += d[i * ch] * d[i * ch]; energyR += d[i * ch + 1] * d[i * ch + 1] }
                }
                stereo = ch >= 2
            }
        }
        let delivered = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let end = (sb.presentationTimeStamp + sb.duration).seconds
        if end.isFinite, delivered - end > -1, delivered - end < 2 {
            let ms = (delivered - end) * 1000
            captureLatencyMs = captureLatencyMs == 0 ? ms : captureLatencyMs * 0.95 + ms * 0.05
        }
        updateBalance(stereo ? energyL : 0, stereo ? energyR : 0, frames: frames)
        detectBeats(mono, sampleRate: asbd.mSampleRate)
        analyze(mono, sampleRate: asbd.mSampleRate)
    }

    private func analyze(_ samples: [Float], sampleRate: Double) {
        ring.append(contentsOf: samples)
        if ring.count > n { ring.removeFirst(ring.count - n) }
        guard ring.count == n else { return }

        // Range of dB treated as "quiet → loud" below each tracked peak; sensitivity widens it.
        let range = 18 + sensitivity * 0.3

        // Loudness (RMS in dB, relative to a slowly falling peak)
        let rms = Double(vDSP.rootMeanSquare(samples))
        let silent = rms < 1e-4
        let loudDb = 20 * log10(rms + 1e-9)
        loudPeak = max(loudDb, loudPeak - 0.04, -60)
        let loudTarget = silent ? 0 : clamp((loudDb - (loudPeak - range)) / range)
        loudness = smooth(loudness, loudTarget)

        // Spectrum
        var windowed = [Float](repeating: 0, count: n)
        vDSP.multiply(ring, window, result: &windowed)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        let lowHz = 40.0, highHz = min(14000.0, sampleRate / 2 - 100)
        let binHz = sampleRate / Double(n)
        let globalPeak = bandPeak.max() ?? -40
        for b in 0 ..< Self.bandCount {
            let f0 = lowHz * pow(highHz / lowHz, Double(b) / Double(Self.bandCount))
            let f1 = lowHz * pow(highHz / lowHz, Double(b + 1) / Double(Self.bandCount))
            let lo = max(1, Int(f0 / binHz)), hi = min(n / 2, max(lo + 1, Int(f1 / binHz)))
            var sum: Float = 0
            for i in lo ..< hi { sum += mags[i] }
            let e = Double(sum) / Double(hi - lo)
            let db = 20 * log10(e + 1e-9)
            // Per-band peak keeps every band lively, but never below (global peak - 30 dB) so hiss stays dark.
            bandPeak[b] = max(db, bandPeak[b] - 0.05, globalPeak - 30)
            let target = silent ? 0 : clamp((db - (bandPeak[b] - range)) / range)
            bands[b] = smooth(bands[b], target)
        }

    }

    /// Kick detection straight on the samples (low-pass ~150 Hz, 256-sample blocks ≈ 5 ms), so a beat
    /// is flagged as soon as its buffer arrives instead of waiting for it to fill an FFT window.
    private func detectBeats(_ samples: [Float], sampleRate: Double) {
        let a = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        // Sensitivity 0 → needs 1.9× the recent bass level, 100 → 1.1×.
        let threshold = 1.9 - sensitivity * 0.008
        // ... and a sharp rise: 1.5× (sensitivity 0) to 1.2× (100) the lowest level of the last ~40 ms.
        // Without it a long, wobbling 808 note re-triggered every 150 ms, flashing new colors mid-note.
        let rise = 1.5 - sensitivity * 0.003
        let block = 256
        var start = 0
        while start < samples.count {
            let end = min(start + block, samples.count)
            var sum: Float = 0
            for i in start ..< end {
                lp1 += a * (samples[i] - lp1)
                lp2 += a * (lp1 - lp2)
                sum += lp2 * lp2
            }
            blockSums[blockIndex] = sum
            blockCounts[blockIndex] = end - start
            blockIndex = (blockIndex + 1) % blockSums.count
            let e = Double(sqrt(blockSums.reduce(0, +) / Float(max(1, blockCounts.reduce(0, +)))))
            bassPeak = max(e, bassPeak * 0.9995)
            sinceBeat += Double(end - start) / sampleRate
            let rel = e > 0.002 && bassPeak > 0 ? min(e / bassPeak, 1) : 0
            bass = rel > bass ? bass + (rel - bass) * 0.5 : bass * 0.975 + rel * 0.025
            kickRef = max(e, kickRef * 0.99983)
            let strength = e > 0.002 && kickRef > 0 ? min(e / kickRef, 1) : 0
            if sinceBeat < 0.08 { beatStrength = max(beatStrength, strength); lastBeatPeak = max(lastBeatPeak, e) }
            let mask = lastBeatPeak * 0.85 * exp(-sinceBeat / 0.5)
            let floor = bassRecent.min() ?? 0
            bassRecent[bassRecentIndex] = e
            bassRecentIndex = (bassRecentIndex + 1) % bassRecent.count
            if e > 0.002, e > bassSlow * threshold, e > bassPeak * 0.3, e > bassPrev, e > floor * rise, e > mask,
               sinceBeat > 0.15 {
                beat = 1
                beatStrength = strength
                lastBeatPeak = e
                beatCount &+= 1
                sinceBeat = 0
                onBeat?()
            }
            bassPrev = e
            bassSlow = bassSlow == 0 ? e : bassSlow * 0.985 + e * 0.015
            start = end
        }
    }

    /// Left/right balance in dB, mapped so ±12 dB is ±1. Silence and mono drift back to centered.
    private func updateBalance(_ l: Float, _ r: Float, frames: Int) {
        let quiet = Float(frames) * 1e-7   // ≈ -70 dBFS RMS
        var target = 0.0
        if l + r > quiet * 2 {
            let db = 10 * log10(Double(r + quiet) / Double(l + quiet))
            target = min(max(db / 12, -1), 1)
        }
        // ~0.4 s to settle, so a panned instrument moves the light but drum hits and reverb don't flicker it.
        balance += (target - balance) * 0.03
    }

    private func smooth(_ old: Double, _ new: Double) -> Double {
        new > old ? old + (new - old) * 0.7 : old * 0.82 + new * 0.18
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}
