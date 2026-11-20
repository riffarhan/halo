import AVFoundation
import CoreMedia
@testable import Halo

/// Synthetic audio for detector tests: feeds generated stereo samples to an `AudioAnalyzer` in 10 ms buffers,
/// the way ScreenCaptureKit delivers them. The detectors are timed by samples, so this runs faster than real time.
enum Synth {
    static let rate = 48000.0
    private static let chunk = 480
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!

    /// Feeds `seconds` of audio; `gen(sampleIndex)` returns (left, right). `each` runs after every buffer.
    static func feed(_ a: AudioAnalyzer, seconds: Double, startingAt start: Int = 0,
                     each: ((Int) -> Void)? = nil, _ gen: (Int) -> (Float, Float)) {
        var t = start
        let end = start + Int(seconds * rate)
        while t < end {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
            b.frameLength = AVAudioFrameCount(chunk)
            for i in 0 ..< chunk {
                let (l, r) = gen(t + i)
                b.floatChannelData![0][i] = l
                b.floatChannelData![1][i] = r
            }
            var desc: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
            var sb: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                            presentationTimeStamp: CMTime(value: Int64(t), timescale: Int32(rate)),
                                            decodeTimeStamp: .invalid)
            CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                 formatDescription: desc, sampleCount: chunk, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
            CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                           flags: 0, bufferList: b.audioBufferList)
            a.process(sb!)
            t += chunk
            each?(t)
        }
    }

    static func mono(_ a: AudioAnalyzer, seconds: Double, startingAt start: Int = 0, _ gen: (Int) -> Float) {
        feed(a, seconds: seconds, startingAt: start) { let s = gen($0); return (s, s) }
    }

    /// Deterministic noise so test results don't vary run to run.
    struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
    }

    // MARK: Instruments

    /// Kick: pitch drops from ~115 Hz to 55 Hz over a few ms, 150 ms long.
    static func kick(_ i: Int, every: Int, amp: Float) -> Float {
        let k = i % every
        guard k < 7200 else { return 0 }
        let t = Float(k) / Float(rate)
        return amp * exp(-t * 25) * sin(2 * .pi * (55 + 60 * exp(-t * 30)) * t)
    }

    /// 808 note: long, decaying 50 Hz tone with a 7 Hz wobble of `depth`.
    static func eight08(_ i: Int, every: Int, depth: Float, decay: Float) -> Float {
        let t = Float(i % every) / Float(rate)
        return 0.8 * min(1, t * 200) * exp(-t * decay) * (1 + depth * sin(2 * .pi * 7 * t)) * sin(2 * .pi * 50 * t)
    }
}
