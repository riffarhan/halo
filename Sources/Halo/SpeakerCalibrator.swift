import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Measures how late the current speaker really plays sound: schedules short beeps at exact host
/// times and finds them in a recording from the Mac's built-in microphone.
enum SpeakerCalibrator {
    struct Result {
        var latencyMs: Double
        /// Median distance of the individual measurements from the result.
        var spreadMs: Double
        var heard: Int
        var total: Int
    }

    enum Failure: LocalizedError {
        case microphoneDenied, noMicrophone, notHeard(Int, Int), inconsistent(Double)
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Halo needs Microphone access to hear the test beeps."
            case .noMicrophone: "No built-in microphone found."
            case let .notHeard(h, t): "Only heard \(h) of \(t) beeps. Pause any music, turn the speaker up to a normal listening level and try again."
            case let .inconsistent(s): String(format: "Measurements disagreed by ±%.0f ms. Keep the room quiet and try again.", s)
            }
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        var samples: [Float] = []
        /// (index of first sample, host time in seconds of that sample)
        var chunks: [(start: Int, host: Double)] = []

        func append(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
            guard time.isHostTimeValid, let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            lock.lock()
            chunks.append((samples.count, AVAudioTime.seconds(forHostTime: time.hostTime)))
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
            lock.unlock()
        }

        func snapshot() -> ([Float], [(start: Int, host: Double)]) {
            lock.lock(); defer { lock.unlock() }
            return (samples, chunks)
        }
    }

    static func run(beeps: Int = 8, spacing: Double = 0.75) async throws -> Result {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphoneDenied }
        guard let mic = builtInMicrophone() else { throw Failure.noMicrophone }

        // Two engines: one engine can't record from the built-in mic and play to a different (Bluetooth) device.
        let recordEngine = AVAudioEngine()
        // Always listen with the built-in mic, so a Bluetooth headset never drops into call-quality mode.
        var micID = mic
        if let unit = recordEngine.inputNode.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &micID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let input = recordEngine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        let inRate = inFormat.sampleRate
        let inputLatency = inputLatencySeconds(mic)
        let recorder = Recorder()
        input.installTap(onBus: 0, bufferSize: 512, format: inFormat) { buffer, time in recorder.append(buffer, time) }

        let playEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        playEngine.attach(player)
        let outRate = playEngine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: outRate > 0 ? outRate : 48000, channels: 2) else {
            throw Failure.noMicrophone
        }
        playEngine.connect(player, to: playEngine.mainMixerNode, format: format)
        let beep = makeBeep(format)

        try recordEngine.start()
        defer { input.removeTap(onBus: 0); recordEngine.stop() }
        try playEngine.start()
        defer { playEngine.stop() }
        player.play()
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let first = now + 0.8
        var scheduled: [Double] = []
        for k in 0 ..< beeps {
            let t = first + Double(k) * spacing
            scheduled.append(t)
            player.scheduleBuffer(beep, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: t)), options: [], completionHandler: nil)
        }
        try await Task.sleep(for: .seconds(first - now + Double(beeps) * spacing + 0.8))
        player.stop()

        let (samples, chunks) = recorder.snapshot()
        return try analyze(samples: samples, chunks: chunks, rate: inRate, inputLatency: inputLatency,
                           scheduled: scheduled, window: spacing - 0.05)
    }

    /// 8 ms, 2 kHz tone with a smooth envelope: sharp enough to time to ~1 ms, easy to pick out of room noise.
    /// 20 ms, 2 kHz tone with a smooth envelope. The same waveform is the template the recording is matched against.
    private static func waveform(rate: Double) -> [Float] {
        let n = Int(rate * 0.02)
        return (0 ..< n).map { i in
            let env = sin(Double.pi * Double(i) / Double(n))
            return Float(0.9 * env * sin(2 * Double.pi * 2000 * Double(i) / rate))
        }
    }

    private static func makeBeep(_ format: AVAudioFormat) -> AVAudioPCMBuffer {
        let wave = waveform(rate: format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wave.count))!
        buffer.frameLength = AVAudioFrameCount(wave.count)
        for c in 0 ..< Int(format.channelCount) {
            wave.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: wave.count) }
        }
        return buffer
    }

    private static func analyze(samples: [Float], chunks: [(start: Int, host: Double)], rate: Double,
                                inputLatency: Double, scheduled: [Double], window: Double) throws -> Result {
        guard samples.count > 1, let firstChunk = chunks.first, rate > 0 else { throw Failure.notHeard(0, scheduled.count) }

        // Host time of any recorded sample, using the nearest chunk timestamp before it.
        func host(at index: Int) -> Double {
            var lo = 0, hi = chunks.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if chunks[mid].start <= index { lo = mid } else { hi = mid - 1 }
            }
            return chunks[lo].host + Double(index - chunks[lo].start) / rate
        }
        func index(at hostTime: Double) -> Int {
            max(0, min(samples.count - 1, Int((hostTime - firstChunk.host) * rate)))
        }

        // Matched filter: slide the exact beep waveform along the recording after each scheduled beep.
        // The correlation peaks where the beep starts, even with music or talking in the room.
        let template = waveform(rate: rate)
        let m = template.count
        var latencies: [Double] = []
        for t in scheduled {
            let a = index(at: t), b = min(samples.count - m, index(at: t + window))
            guard b - a > m else { continue }
            let count = b - a
            var corr = [Float](repeating: 0, count: count)
            samples.withUnsafeBufferPointer { s in
                vDSP_conv(s.baseAddress! + a, 1, template, 1, &corr, 1, vDSP_Length(count), vDSP_Length(m))
            }
            var magnitude = corr.map { abs($0) }
            var peak: Float = 0
            var peakIndex: vDSP_Length = 0
            vDSP_maxvi(magnitude, 1, &peak, &peakIndex, vDSP_Length(count))
            magnitude.sort()
            let typical = max(magnitude[count / 2], 1e-9)
            guard peak / typical > 10 else { continue }       // not clearly above the background
            latencies.append(host(at: a + Int(peakIndex)) - inputLatency - t)
        }
        guard latencies.count >= max(3, scheduled.count / 2) else { throw Failure.notHeard(latencies.count, scheduled.count) }
        let sorted = latencies.sorted()
        let median = sorted[sorted.count / 2]
        let spread = latencies.map { abs($0 - median) }.sorted()[latencies.count / 2]
        guard spread < 0.02 else { throw Failure.inconsistent(spread * 1000) }
        return Result(latencyMs: median * 1000, spreadMs: spread * 1000, heard: latencies.count, total: scheduled.count)
    }

    // MARK: Core Audio helpers

    private static func builtInMicrophone() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.first { id in
            var transport = UInt32(0), s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(id, &a, 0, nil, &s, &transport)
            guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            a.mSelector = kAudioDevicePropertyStreams; a.mScope = kAudioObjectPropertyScopeInput
            var streamsSize = UInt32(0)
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    private static func inputLatencySeconds(_ id: AudioDeviceID) -> Double {
        func value(_ sel: AudioObjectPropertySelector) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var v = UInt32(0), s = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v)
            return v
        }
        var rate = Float64(0), s = UInt32(MemoryLayout<Float64>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &a, 0, nil, &s, &rate)
        guard rate > 0 else { return 0 }
        return Double(value(kAudioDevicePropertyLatency) + value(kAudioDevicePropertySafetyOffset)) / rate
    }
}
