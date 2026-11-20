import AudioToolbox
import CoreAudio
import Foundation
import HaloAudio

/// Keeps video in step with Bluetooth audio. Players hold the picture back by the delay the output device
/// reports, and Bluetooth speakers report far less than they really have. When a Bluetooth speaker is the
/// sound output, this makes the Halo Sync virtual device the output instead, forwards the audio to the
/// speaker, and has Halo Sync report the speaker's measured delay.
@MainActor
final class VideoSync {
    struct Route: Equatable {
        var targetID: AudioDeviceID
        var targetUID: String
        var targetName: String
    }

    static let driverUID = "HaloSync_UID"
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/HaloSync.driver"
    private static let savedTargetKey = "videoSync.targetUID"
    private static let rates: [Double] = [44100, 48000, 88200, 96000]

    private(set) var route: Route?
    /// The delay Halo Sync currently reports to apps, in ms.
    private(set) var reportedLatencyMs = 0.0
    private(set) var lastError: String?
    /// Called after any change worth showing.
    var onChange: (() -> Void)?
    /// End-to-end delay to report for a speaker: (name, Core Audio's own figure in ms) → ms.
    var latencyFor: (String, Double) -> Double = { _, reported in reported }

    private var enabled = false
    private var engaging = false
    private var systemListening = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    var driverInstalled: Bool { CA.device(uid: Self.driverUID) != nil }
    var forwarding: Bool { halo_forward_running() != 0 }
    var bufferMs: Double { halo_forward_buffer_ms() }
    var underruns: UInt32 { halo_forward_underruns() }

    func setEnabled(_ on: Bool) {
        enabled = on
        listenToSystem()
        evaluate()
    }

    /// Hand the sound back to the real speaker (on quit).
    func shutdown() {
        enabled = false
        disengage()
    }

    /// Re-read the delay for the current speaker and report it.
    func refreshLatency() {
        guard let halo = CA.device(uid: Self.driverUID), let r = route else { return }
        let ms = latencyFor(r.targetName, CA.reportedLatencyMs(r.targetID))
        CA.setLatency(halo, ms: ms)
        reportedLatencyMs = ms
        onChange?()
    }

    /// Report a specific delay (0 while measuring the speaker through Halo Sync).
    func setReportedLatency(_ ms: Double) {
        guard let halo = CA.device(uid: Self.driverUID) else { return }
        CA.setLatency(halo, ms: ms)
        reportedLatencyMs = ms
        onChange?()
    }

    // MARK: Routing

    private func evaluate() {
        guard !engaging else { return }
        guard enabled, let halo = CA.device(uid: Self.driverUID) else {
            disengage()
            onChange?()
            return
        }
        let current = CA.defaultOutput()
        if current == halo {
            if let r = route, CA.device(uid: r.targetUID) == r.targetID {
                if !forwarding { engage(r.targetID, halo: halo) }
                return
            }
            // Halo Sync is the output but nothing is forwarding (Halo restarted, or the speaker went away).
            if let uid = route?.targetUID ?? UserDefaults.standard.string(forKey: Self.savedTargetKey),
               let target = CA.device(uid: uid), target != halo, CA.hasOutput(target) {
                engage(target, halo: halo)
            } else {
                disengage()
            }
        } else if let current, CA.isBluetooth(current) {
            engage(current, halo: halo)
        } else {
            stopForwarding()
        }
        onChange?()
    }

    private func engage(_ target: AudioDeviceID, halo: AudioDeviceID) {
        engaging = true
        Task { @MainActor in
            defer {
                engaging = false
                onChange?()
                evaluate()
            }
            stopForwarding()
            let name = CA.name(target) ?? "Speaker"
            let uid = CA.uid(target) ?? ""

            // Run Halo Sync at the speaker's rate so the forwarding only corrects clock drift.
            let rate = CA.nominalRate(target)
            let want = Self.rates.contains(rate) ? rate : 48000
            if CA.nominalRate(halo) != want {
                CA.setNominalRate(halo, want)
                for _ in 0 ..< 20 where CA.nominalRate(halo) != want {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            CA.setLatency(halo, ms: latencyFor(name, CA.reportedLatencyMs(target)))
            reportedLatencyMs = latencyFor(name, CA.reportedLatencyMs(target))
            if let v = CA.volume(target) { CA.setVolume(halo, v) }
            CA.setMute(halo, CA.mute(target))

            let err = halo_forward_start(halo, target)
            guard err == noErr else {
                lastError = "Couldn't forward sound to \(name) (error \(err))."
                NSLog("Halo: %@", lastError!)
                route = nil
                if CA.defaultOutput() == halo { CA.setDefaultOutput(target) }
                return
            }
            lastError = nil
            route = Route(targetID: target, targetUID: uid, targetName: name)
            UserDefaults.standard.set(uid, forKey: Self.savedTargetKey)
            if CA.defaultOutput() != halo { CA.setDefaultOutput(halo) }
            watch(target: target, halo: halo)
            NSLog("Halo: video sync → %@, reporting %.0f ms", name, reportedLatencyMs)
        }
    }

    private func stopForwarding() {
        halo_forward_stop()
        removeDeviceListeners()
        route = nil
    }

    /// Stop forwarding and, if Halo Sync is still the output, give the sound back to a real speaker.
    private func disengage() {
        let target = route.map(\.targetUID) ?? UserDefaults.standard.string(forKey: Self.savedTargetKey)
        stopForwarding()
        guard let halo = CA.device(uid: Self.driverUID), CA.defaultOutput() == halo else { return }
        if let uid = target, let t = CA.device(uid: uid), CA.hasOutput(t) {
            CA.setDefaultOutput(t)
        } else if let builtIn = CA.builtInOutput() {
            CA.setDefaultOutput(builtIn)
        }
    }

    // MARK: Listeners

    private func listenToSystem() {
        guard !systemListening else { return }
        systemListening = true
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = CA.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
    }

    private func watch(target: AudioDeviceID, halo: AudioDeviceID) {
        removeDeviceListeners()
        func add(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                 _ handler: @escaping @MainActor () -> Void) {
            var addr = CA.address(selector, scope)
            let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
            if AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr {
                listeners.append((id, addr, block))
            }
        }
        // The speaker went away or changed rate (Bluetooth drops to call quality when its mic is used): re-route.
        add(target, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) { [weak self] in
            self?.stopForwarding(); self?.evaluate()
        }
        add(target, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) { [weak self] in
            self?.stopForwarding(); self?.evaluate()
        }
        add(halo, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) { [weak self] in
            guard CA.nominalRate(halo) != CA.nominalRate(target) else { return }
            self?.stopForwarding(); self?.evaluate()
        }
        // Volume keys change Halo Sync; pass that on to the speaker, and the other way round.
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            add(halo, selector, kAudioObjectPropertyScopeOutput) {
                if let v = CA.volume(halo), let t = CA.volume(target), abs(v - t) > 0.005 { CA.setVolume(target, v) }
                if CA.mute(halo) != CA.mute(target) { CA.setMute(target, CA.mute(halo)) }
            }
            add(target, selector, kAudioObjectPropertyScopeOutput) {
                if let t = CA.volume(target), let v = CA.volume(halo), abs(v - t) > 0.005 { CA.setVolume(halo, t) }
                if CA.mute(halo) != CA.mute(target) { CA.setMute(halo, CA.mute(target)) }
            }
        }
    }

    private func removeDeviceListeners() {
        for (id, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        listeners.removeAll()
    }
}

// MARK: - Core Audio helpers

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> OSStatus {
        var addr = address(selector, scope)
        var v = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func name(_ id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }
    static func uid(_ id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    static func device(uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func defaultOutput() -> AudioDeviceID? {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, id)
    }

    static func transport(_ id: AudioDeviceID) -> UInt32 {
        get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = transport(id)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func builtInOutput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasOutput($0) }
    }

    static func nominalRate(_ id: AudioDeviceID) -> Double {
        get(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
    }

    static func setNominalRate(_ id: AudioDeviceID, _ rate: Double) {
        set(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(rate))
    }

    /// What Core Audio says the output adds (device + stream latency, safety offset, buffer), in ms.
    static func reportedLatencyMs(_ id: AudioDeviceID) -> Double {
        let out = kAudioObjectPropertyScopeOutput
        var frames = (get(id, kAudioDevicePropertyLatency, out, UInt32(0)) ?? 0)
            + (get(id, kAudioDevicePropertySafetyOffset, out, UInt32(0)) ?? 0)
            + (get(id, kAudioDevicePropertyBufferFrameSize, out, UInt32(0)) ?? 0)
        var addr = address(kAudioDevicePropertyStreams, out)
        var size = UInt32(0)
        if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams)
            if let s = streams.first { frames += get(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0 }
        }
        let rate = nominalRate(id)
        return rate > 0 ? Double(frames) / rate * 1000 : 0
    }

    static func volume(_ id: AudioDeviceID) -> Float32? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        guard AudioHardwareServiceHasProperty(id, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioHardwareServiceGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setVolume(_ id: AudioDeviceID, _ value: Float32) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        guard AudioHardwareServiceHasProperty(id, &addr) else { return }
        var v = min(max(value, 0), 1)
        AudioHardwareServiceSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func mute(_ id: AudioDeviceID) -> Bool {
        (get(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, UInt32(0)) ?? 0) != 0
    }

    static func setMute(_ id: AudioDeviceID, _ on: Bool) {
        set(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, UInt32(on ? 1 : 0))
    }

    /// Halo Sync's custom 'hlat' property: the delay it reports to apps, in ms.
    static func setLatency(_ halo: AudioDeviceID, ms: Double) {
        var addr = address(0x686C_6174)
        var value: CFPropertyList = NSNumber(value: max(0, min(ms, 1500)))
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(halo, &addr, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
        if status != noErr { NSLog("Halo: setting Halo Sync latency failed (%d)", status) }
    }

    static func latencyFrames(_ id: AudioDeviceID) -> UInt32 {
        get(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, UInt32(0)) ?? 0
    }
}
