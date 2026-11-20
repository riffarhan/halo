import AVFoundation

/// Plays a deep kick with a short click on top every 0.6 s through the current output, for lining up
/// the lights with the sound by eye.
final class SyncTestPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    func start() {
        engine.attach(player)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48000, channels: 2) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let period = 0.6
        let frames = AVAudioFrameCount(period * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let sr = format.sampleRate
        for i in 0 ..< Int(0.25 * sr) {
            let t = Double(i) / sr
            // Kick: pitch drops from ~150 Hz to 50 Hz; click: 4 ms of 2 kHz so small speakers mark the onset too.
            let phase = 2 * Double.pi * (50 * t + 100 * (1 - exp(-t * 30)) / 30)
            var v = 0.85 * exp(-t * 9) * sin(phase)
            if t < 0.004 { v += 0.35 * sin(2 * Double.pi * 2000 * t) * (1 - t / 0.004) }
            for c in 0 ..< Int(format.channelCount) { buffer.floatChannelData![c][i] = Float(v) }
        }
        do { try engine.start() } catch { NSLog("Halo: sync test audio failed: %@", error.localizedDescription); return }
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
