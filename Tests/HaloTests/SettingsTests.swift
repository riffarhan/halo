import Testing
@testable import Halo

@Suite struct BrightnessTests {
    @Test func sliderFollowsTheEye() {
        #expect(LightController.brightnessScale(100) == 1)
        #expect(abs(LightController.brightnessScale(50) - 0.2575) < 1e-9)
        #expect(LightController.brightnessScale(1) >= 0.01 && LightController.brightnessScale(1) < 0.02)
        #expect(LightController.brightnessScale(0) == LightController.brightnessScale(1))
    }
}

@Suite struct PresetTests {
    @Test func eachPresetMatchesItselfAndOnlyItself() {
        for p in Preset.allCases {
            var s = Settings()
            p.apply(to: &s)
            #expect(Preset.current(s) == p, "\(p) applied reads as \(String(describing: Preset.current(s)))")
        }
    }

    @Test func editingAnAdvancedSettingMakesItCustom() {
        var s = Settings()
        Preset.club.apply(to: &s)
        s.partyIntensity = 59
        #expect(Preset.current(s) == nil)
        Preset.groove.apply(to: &s)
        s.musicDynamics = 80
        #expect(Preset.current(s) == nil)
    }

    @Test func paletteAndStrobeAreNotPartOfAPreset() {
        var s = Settings()
        Preset.club.apply(to: &s)
        s.musicPalette = .ocean
        s.partyStrobe = true
        #expect(Preset.current(s) == .club)
    }
}
