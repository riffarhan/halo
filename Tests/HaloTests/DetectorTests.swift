import Foundation
import Testing
@testable import Halo

/// Kick, snare and song-energy detection on synthetic audio. These pin down behaviour that was tuned by ear and
/// by recordings, so a later change can't quietly bring back double kicks, hi-hats read as snares, and so on.
@Suite struct KickTests {
    @Test func realistic808NoteCountsOnce() {
        let a = AudioAnalyzer()
        Synth.mono(a, seconds: 6.4) { Synth.eight08($0, every: 76800, depth: 0.2, decay: 0.8) }
        #expect(a.beatCount == 4)
    }

    @Test func softKickAfterLoudOneStillCounts() {
        let a = AudioAnalyzer()
        Synth.mono(a, seconds: 4) { Synth.kick($0, every: 24000, amp: ($0 / 24000) % 2 == 0 ? 0.9 : 0.45) }
        #expect(a.beatCount == 8)
    }

    @Test func fastKicksAllCount() {
        let a = AudioAnalyzer()
        var n = Synth.Noise(seed: 1)
        Synth.mono(a, seconds: 3) { Synth.kick($0, every: 12000, amp: 0.7) + 0.02 * n.next() }
        #expect(a.beatCount == 12)
    }

    @Test func kickStrengthFollowsHowHardItHits() {
        let a = AudioAnalyzer()
        var strengths: [Double] = []
        var seen = 0
        // 4 hard kicks, then 4 at half amplitude; read strength 100 ms after each kick (after it has peaked).
        Synth.feed(a, seconds: 4, each: { t in
            if a.beatCount != seen, t % 24000 >= 4800 { seen = a.beatCount; strengths.append(a.beatStrength) }
        }) { let s = Synth.kick($0, every: 24000, amp: $0 < 96000 ? 0.9 : 0.45); return (s, s) }
        #expect(strengths.count == 8)
        let hard = strengths.prefix(4).last ?? 0, soft = strengths.suffix(4).last ?? 0
        #expect(hard > 0.9)
        #expect(soft > 0.35 && soft < 0.7)
    }

    @Test func kickOnlyLoopsMakeNoSnares() {
        let a = AudioAnalyzer()
        Synth.mono(a, seconds: 4) { Synth.kick($0, every: 24000, amp: 0.8) }
        #expect(a.snareCount == 0)
    }
}

/// A 100 BPM loop: kick on 1 and 3, snare or clap on 2 and 4, hi-hats on every 8th, over a 55 Hz bass pad.
private func drumLoop(snare kind: Int, snareAmp: Float, hatAmp: Float, seconds: Double = 12) -> AudioAnalyzer {
    let a = AudioAnalyzer()
    let rate = Float(Synth.rate)
    let beat = Int(Synth.rate * 0.6)
    var n = Synth.Noise(seed: 7)
    var hp1: Float = 0, hp2: Float = 0, sl1: Float = 0, sl2: Float = 0, cb1: Float = 0, cb2: Float = 0
    Synth.mono(a, seconds: seconds) { i in
        let k = i % beat, t = Float(k) / rate
        var s: Float = 0.08 * sin(2 * .pi * 55 * Float(i) / rate)
        if (i / beat) % 2 == 0 {
            s += 0.8 * exp(-t * 25) * sin(2 * .pi * (55 + 60 * exp(-t * 30)) * t)
        } else if kind == 0 {
            // Snare: wires (noise low-passed around 5 kHz) plus a 190 Hz body.
            let w = n.next(); sl1 += 0.48 * (w - sl1); sl2 += 0.48 * (sl1 - sl2)
            s += snareAmp * (exp(-t * 18) * sl2 * 1.6 + exp(-t * 30) * 0.5 * sin(2 * .pi * 190 * t))
        } else {
            // Clap: three quick bursts of band-passed (1–3 kHz) noise.
            let w = n.next(); cb1 += 0.33 * (w - cb1); let bp = cb1 - cb2; cb2 += 0.12 * (cb1 - cb2)
            for d: Float in [0, 0.011, 0.023] where t >= d { s += snareAmp * 1.6 * exp(-(t - d) * 60) * bp }
        }
        // Closed hi-hat: noise high-passed twice around 7 kHz.
        let ht = Float(i % (beat / 2)) / rate
        let w = n.next(); hp1 += 0.6 * (w - hp1); let h1 = w - hp1; hp2 += 0.6 * (h1 - hp2)
        s += hatAmp * exp(-ht * 70) * (h1 - hp2) * 1.5
        return s
    }
    return a
}

@Suite struct SnareTests {
    @Test func snaresUnderQuietHats() {
        let a = drumLoop(snare: 0, snareAmp: 0.5, hatAmp: 0.15)
        #expect(a.snareCount == 10)
        #expect(a.beatCount == 10)
    }

    @Test func claps() {
        let a = drumLoop(snare: 1, snareAmp: 0.5, hatAmp: 0.15)
        #expect(a.snareCount == 10)
    }

    @Test func snaresUnderLoudHats() {
        let a = drumLoop(snare: 0, snareAmp: 0.5, hatAmp: 0.4)
        #expect(a.snareCount == 10)
    }

    @Test func hatsAloneAreNotSnares() {
        let a = drumLoop(snare: 0, snareAmp: 0, hatAmp: 0.4)
        #expect(a.snareCount == 0)
    }

    @Test func snareBodyIsNotAKick() {
        let a = drumLoop(snare: 0, snareAmp: 0.5, hatAmp: 0.15)
        #expect(a.beatCount == 10)
    }
}

@Suite struct StereoTests {
    @Test func balanceFollowsPanning() {
        var n = Synth.Noise(seed: 3)
        for (gl, gr, lo, hi) in [(Float(1), Float(1), -0.05, 0.05), (1, 0.15, -1.0, -0.8), (0.05, 1, 0.8, 1.0)] {
            let a = AudioAnalyzer()
            Synth.feed(a, seconds: 1.5) { _ in let s = 0.2 * n.next(); return (s * gl, s * gr) }
            #expect(a.balance >= lo && a.balance <= hi, "balance \(a.balance) for gains \(gl)/\(gr)")
        }
    }
}

/// Kick and snare times are what the lights are scheduled from, so they must point at the hit in the audio,
/// not at when it was detected.
@Suite struct TimingTests {
    @Test func kickTimeIsTheOnset() {
        let a = AudioAnalyzer()
        var times: [Double] = []
        a.onBeat = { times.append(a.lastBeatTime) }
        // Synth stamps buffers with sample-index / rate as presentation time, so onsets are at 0, 0.5, 1.0 … s.
        Synth.mono(a, seconds: 3) { Synth.kick($0, every: 24000, amp: 0.8) }
        #expect(times.count == 6)
        for (k, t) in times.enumerated() {
            #expect(abs(t - Double(k) * 0.5) < 0.008, "kick \(k) at \(t)")
        }
    }

    @Test func snareTimeIsTheOnsetNotTheConfirmation() {
        var hits: [Double] = []
        let a = AudioAnalyzer()
        a.onSnare = { hits.append(a.lastSnareTime) }
        let rate = Float(Synth.rate)
        var n = Synth.Noise(seed: 11)
        var c1: Float = 0, c2: Float = 0
        // Kick at 0.0, clap at 0.6, kick at 1.2, clap at 1.8 …
        Synth.mono(a, seconds: 4.8) { i in
            let beat = Int(Synth.rate * 0.6), k = i % beat, t = Float(k) / rate
            if (i / beat) % 2 == 0 { return Synth.kick(i, every: beat * 2, amp: 0.8) }
            let w = n.next(); c1 += 0.33 * (w - c1); let bp = c1 - c2; c2 += 0.12 * (c1 - c2)
            return 0.8 * exp(-t * 60) * bp
        }
        #expect(hits.count == 4)
        for (k, t) in hits.enumerated() {
            #expect(abs(t - (0.6 + Double(k) * 1.2)) < 0.012, "snare \(k) at \(t)")
        }
    }
}

@Suite struct TempoTests {
    private func kicks(bpm: Double, seconds: Double, skip: (Int) -> Bool = { _ in false }) -> AudioAnalyzer {
        let a = AudioAnalyzer()
        let period = Int(Synth.rate * 60 / bpm)
        Synth.mono(a, seconds: seconds) { i in skip(i / period) ? 0 : Synth.kick(i, every: period, amp: 0.8) }
        return a
    }

    @Test func fourOnTheFloor() {
        let a = kicks(bpm: 124, seconds: 10)
        #expect(abs(a.bpm - 124) < 2, "bpm \(a.bpm)")
    }

    @Test func kicksOnOneAndThreeStillGiveTheBeat() {
        // Kick every other beat at 100 BPM: gaps of 1.2 s.
        let a = kicks(bpm: 50, seconds: 14)
        #expect(abs(a.bpm - 100) < 2, "bpm \(a.bpm)")
    }

    @Test func missingKicksDontChangeTheTempo() {
        let a = kicks(bpm: 120, seconds: 10) { $0 % 5 == 4 }
        #expect(abs(a.bpm - 120) < 2, "bpm \(a.bpm)")
    }

    @Test func phrasesStepEvery16Beats() {
        // 128 BPM for 32 beats: the phrase steps at beat 16 and 32 (kicks 17 and 33 start new phrases).
        let a = kicks(bpm: 128, seconds: 60.0 / 128 * 32 + 0.2)
        #expect(a.phrase == 2, "phrase \(a.phrase)")
    }
}

@Suite struct SongEnergyTests {
    /// Noise plus a 55 Hz line at `music`, kicks at `kick` every `every` samples.
    private func section(_ a: AudioAnalyzer, _ seconds: Double, music: Float, kick: Float, every: Int,
                         noise n: inout Synth.Noise, at start: inout Int) -> Double {
        let s0 = start
        Synth.mono(a, seconds: seconds, startingAt: s0) { i in
            music * n.next() + music * 1.2 * sin(2 * .pi * 55 * Float(i) / Float(Synth.rate))
                + (kick > 0 ? Synth.kick(i, every: every, amp: kick) : 0)
        }
        start += Int(seconds * Synth.rate)
        return a.energy
    }

    @Test func versesCalmChorusesBig() {
        let a = AudioAnalyzer()
        var n = Synth.Noise(seed: 5)
        var t = 0
        _ = section(a, 12, music: 0.04, kick: 0, every: 24000, noise: &n, at: &t)                       // intro
        let verse1 = section(a, 20, music: 0.06, kick: 0.3, every: 48000, noise: &n, at: &t)
        let chorus1 = section(a, 20, music: 0.15, kick: 0.8, every: 24000, noise: &n, at: &t)
        let verse2 = section(a, 20, music: 0.06, kick: 0.3, every: 48000, noise: &n, at: &t)
        let chorus2 = section(a, 16, music: 0.16, kick: 0.85, every: 24000, noise: &n, at: &t)
        #expect(verse1 <= 0.7, "first verse \(verse1)")
        #expect(chorus1 > 0.9, "chorus \(chorus1)")
        #expect(verse2 < 0.35, "second verse \(verse2)")
        #expect(chorus2 > 0.9, "last chorus \(chorus2)")
    }

    @Test func sectionChangeStartsANewPhrase() {
        let a = AudioAnalyzer()
        var n = Synth.Noise(seed: 9)
        var t = 0
        _ = section(a, 20, music: 0.05, kick: 0.3, every: 24000, noise: &n, at: &t)
        let before = a.phrase
        _ = section(a, 8, music: 0.16, kick: 0.85, every: 24000, noise: &n, at: &t)
        // 20 s at 120 BPM is 40 beats → 2 phrases; the chorus adds one at its start (within 8 s, before 16 beats).
        #expect(a.phrase > before, "phrase \(before) → \(a.phrase)")
    }

    @Test func silenceStartsANewSong() {
        let a = AudioAnalyzer()
        var t = 0
        var n = Synth.Noise(seed: 2)
        _ = section(a, 10, music: 0.1, kick: 0.8, every: 24000, noise: &n, at: &t)
        #expect(a.bpm > 0)
        Synth.mono(a, seconds: 3, startingAt: t) { _ in 0 }
        #expect(a.bpm == 0)
    }
}

@Suite struct HatTests {
    @Test func hatsAreCountedAndSnaresAreNot() {
        // 100 BPM, hats on every 8th for 12 s = 40 hats.
        let hats = drumLoop(snare: 0, snareAmp: 0, hatAmp: 0.3)
        #expect(hats.hatCount >= 36 && hats.hatCount <= 42, "hats \(hats.hatCount)")
        let snares = drumLoop(snare: 0, snareAmp: 0.6, hatAmp: 0)
        #expect(snares.hatCount <= 3, "hats in a snare-only loop: \(snares.hatCount)")
    }
}
