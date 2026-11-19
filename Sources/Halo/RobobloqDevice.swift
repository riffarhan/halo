import Foundation
import IOKit.hid

/// Finds the controller over USB HID, tracks plug/unplug, and writes packets on a serial queue.
/// Callbacks (`onConnectionChange`, `onDeviceInfo`) arrive on the main thread.
final class RobobloqDevice: @unchecked Sendable {
    var onConnectionChange: ((Bool) -> Void)?
    var onDeviceInfo: ((DeviceInfo) -> Void)?

    private let manager: IOHIDManager
    private var mainDevice: IOHIDDevice?                 // main thread
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Robobloq.reportSize)

    private let io = DispatchQueue(label: "halo.hid.io", qos: .userInteractive)
    private var ioDevice: IOHIDDevice?                   // io queue
    private var index: UInt8 = 2                         // io queue

    // Latest-frame slot: if the device is slower than the producer, stale frames are dropped.
    private let frameLock = NSLock()
    private var pendingFrame: [UInt8]?
    private var frameScheduled = false

    var isConnected: Bool { mainDevice != nil }

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Robobloq.vendorID,
            kIOHIDProductIDKey: Robobloq.productID,
            kIOHIDPrimaryUsagePageKey: Robobloq.usagePage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    }

    deinit { inputBuffer.deallocate() }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<RobobloqDevice>.fromOpaque(ctx!).takeUnretainedValue().attached(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<RobobloqDevice>.fromOpaque(ctx!).takeUnretainedValue().detached(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess { NSLog("Halo: IOHIDManagerOpen failed 0x%08x", r) }
    }

    private func attached(_ device: IOHIDDevice) {
        guard mainDevice == nil else { return }
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { NSLog("Halo: IOHIDDeviceOpen failed 0x%08x", r); return }
        mainDevice = device
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, Robobloq.reportSize, { ctx, _, _, _, _, report, length in
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<RobobloqDevice>.fromOpaque(ctx!).takeUnretainedValue().received(bytes)
        }, ctx)
        io.sync { ioDevice = device; index = 2 }
        onConnectionChange?(true)
    }

    private func detached(_ device: IOHIDDevice) {
        guard let current = mainDevice, CFEqual(current, device) else { return }
        mainDevice = nil
        io.sync { ioDevice = nil }
        onConnectionChange?(false)
    }

    private func received(_ bytes: [UInt8]) {
        // Most replies are plain acks; only device info is interesting.
        if let info = Robobloq.parseDeviceInfo(bytes) { onDeviceInfo?(info) }
    }

    // MARK: Sending

    func send(_ body: [UInt8]) {
        io.async { self.writeShort(body) }
    }

    /// Blocks until written. For use at quit time.
    func sendNow(_ bodies: [[UInt8]]) {
        io.sync { bodies.forEach(self.writeShort) }
    }

    /// Per-LED frame (sync-screen command). Only the most recent pending frame is sent.
    func sendFrame(_ rangePayload: [UInt8]) {
        frameLock.lock()
        pendingFrame = rangePayload
        let needsSchedule = !frameScheduled
        frameScheduled = true
        frameLock.unlock()
        if needsSchedule { io.async { self.flushFrame() } }
    }

    func dropPendingFrame() {
        frameLock.lock(); pendingFrame = nil; frameLock.unlock()
    }

    private func flushFrame() {
        frameLock.lock()
        let payload = pendingFrame
        pendingFrame = nil
        frameScheduled = false
        frameLock.unlock()
        guard let payload, let device = ioDevice else { return }
        for report in Robobloq.longPacket(command: Robobloq.Cmd.syncScreen, payload: payload, index: nextIndex()) {
            write(device, report)
        }
    }

    private func writeShort(_ body: [UInt8]) {
        guard let device = ioDevice else { return }
        write(device, Robobloq.shortPacket(body, index: nextIndex()))
    }

    private func nextIndex() -> UInt8 {
        defer { index &+= 1 }
        return index
    }

    private func write(_ device: IOHIDDevice, _ report: [UInt8]) {
        let r = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        if r != kIOReturnSuccess { NSLog("Halo: write failed 0x%08x", r) }
    }
}
