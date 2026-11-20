import Foundation

/// One-click looks for Music mode. A preset only sets how the lights react (style, motion, accents, tuning);
/// palette, strobe and speaker sync stay as you set them. Change anything under Advanced and the preset reads
/// "Custom", so a setting can't silently change how a preset looks.
enum Preset: String, CaseIterable, Identifiable {
    case chill, groove, party, club

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var summary: String {
        switch self {
        case .chill: "Spectrum colors drift slowly with the music. No flashes."
        case .groove: "Spectrum follows the bass: colors jump on kicks, snares flash the top, hi-hats shimmer on the treble side."
        case .party: "Party patterns, softened: colors fade into each other on the beat and the strip never goes dark."
        case .club: "The original Party: hard hits, a new color every kick, a new pattern every phrase."
        }
    }

    private struct Look {
        var style: MusicStyle
        var motion: SpectrumMotion = .beat
        var intensity = 100.0
        var snare: Bool
        var hats: Bool
        var energy = true
        var stereo = true
        var tuning: MusicTuning
    }

    private var look: Look {
        switch self {
        case .chill: Look(style: .spectrum, motion: .flow, snare: false, hats: false,
                          tuning: MusicTuning(sensitivity: 40, smoothness: 85))
        case .groove: Look(style: .spectrum, motion: .beat, snare: true, hats: true,
                           tuning: MusicTuning(sensitivity: 30, smoothness: 80))
        case .party: Look(style: .party, intensity: 50, snare: true, hats: false,
                          tuning: MusicTuning(sensitivity: 45, smoothness: 65))
        case .club: Look(style: .party, intensity: 100, snare: true, hats: false, stereo: false,
                         tuning: MusicTuning(sensitivity: 45, smoothness: 65))
        }
    }

    func apply(to s: inout Settings) {
        let l = look
        s.mode = .music
        s.isOn = true
        s.musicStyle = l.style
        if l.style == .spectrum { s.spectrumMotion = l.motion }
        if l.style == .party { s.partyIntensity = l.intensity }
        s.snareAccents = l.snare
        s.hatShimmer = l.hats
        s.songEnergy = l.energy
        s.stereo = l.stereo
        s.tuning = l.tuning
    }

    func matches(_ s: Settings) -> Bool {
        let l = look
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1 }
        return s.musicStyle == l.style
            && (l.style != .spectrum || s.spectrumMotion == l.motion)
            && (l.style != .party || near(s.partyIntensity, l.intensity))
            && s.snareAccents == l.snare && s.hatShimmer == l.hats
            && s.songEnergy == l.energy && s.stereo == l.stereo
            && near(s.tuning.sensitivity, l.tuning.sensitivity) && near(s.tuning.smoothness, l.tuning.smoothness)
    }

    /// The preset the current Music settings match, if any.
    static func current(_ s: Settings) -> Preset? { allCases.first { $0.matches(s) } }
}
