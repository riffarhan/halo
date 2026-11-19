import Foundation

struct RGB: Codable, Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 255, g: 255, b: 255)

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    /// "ff8800", "#FF8800" or "f80".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF))
    }

    var hex: String { String(format: "%02X%02X%02X", r, g, b) }
}

struct DeviceInfo: Equatable {
    var id: String
    var sizeInches: Int
    var ledCount: Int
    var uuid: String
    var firmware: String
}

/// Wire format of the Robobloq USB HID light-strip controller (sold as AKKLED).
/// All traffic is 64-byte output reports with report ID 0.
enum Robobloq {
    static let vendorID = 0x1A86
    static let productID = 0xFE07
    static let usagePage = 0xFF00
    static let reportSize = 64

    enum Cmd {
        static let syncScreen: UInt8 = 0x80
        static let deviceInfo: UInt8 = 0x82
        static let effect: UInt8 = 0x85
        static let color: UInt8 = 0x86
        static let brightness: UInt8 = 0x87
        static let speed: UInt8 = 0x8A
        static let openURL: UInt8 = 0x93
        static let turnOff: UInt8 = 0x97
    }

    static let effectCategoryDynamic: UInt8 = 0x02
    /// Sound-reactive effects driven by the controller's own microphone ("Pickup" in the vendor app).
    static let effectCategoryRhythm: UInt8 = 0x03

    /// Names of the built-in animated effects, by device index.
    static let effectNames = ["Rainbow", "Breathing", "Twist", "Beat", "Twirl", "Lemon", "Electric"]
    /// Names of the microphone-driven effects, by device index.
    static let pickupNames = ["Circles"]

    static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 + Int($1) })
    }

    /// Short "RB" packet: 52 42 <total length> <index> <body...> <checksum>, zero padded.
    static func shortPacket(_ body: [UInt8], index: UInt8) -> [UInt8] {
        precondition(body.count <= reportSize - 5, "body too long for a short packet")
        var p: [UInt8] = [0x52, 0x42, UInt8(body.count + 5), index] + body
        p.append(checksum(p))
        p += [UInt8](repeating: 0, count: reportSize - p.count)
        return p
    }

    /// Long "SC" packet split into 64-byte reports:
    /// 53 43 <len hi> <len lo> <index> <command> <payload...> <checksum>.
    static func longPacket(command: UInt8, payload: [UInt8], index: UInt8) -> [[UInt8]] {
        let n = payload.count + 7
        var d: [UInt8] = [0x53, 0x43, UInt8(n >> 8), UInt8(n & 0xFF), index, command] + payload
        d.append(checksum(d))
        d += [UInt8](repeating: 0, count: (reportSize - d.count % reportSize) % reportSize)
        return stride(from: 0, to: d.count, by: reportSize).map { Array(d[$0 ..< $0 + reportSize]) }
    }

    // MARK: Command bodies

    /// `93 00`: tells the controller not to ask the PC to open the vendor site. It also
    /// resets the controller's packet parser when it has stalled and is ignoring frames.
    static let unstickBody: [UInt8] = [Cmd.openURL, 0x00]

    static func solidBody(_ c: RGB, ledCount: Int) -> [UInt8] {
        let n = UInt8(clamping: max(1, min(ledCount, 254)))
        // One range covering every LED, followed by the dummy range the vendor app also sends.
        return [Cmd.color, 1, c.r, c.g, c.b, n, n + 1, 0, 0, 0, 0xFE]
    }

    static func brightnessBody(percent: Double) -> [UInt8] {
        // 0 is read by the device as "max", so the floor is 1.
        [Cmd.brightness, UInt8(clamping: max(1, Int((percent / 100 * 255).rounded())))]
    }

    static func effectBody(_ index: Int) -> [UInt8] {
        [Cmd.effect, effectCategoryDynamic, UInt8(clamping: index)]
    }

    /// Device codes of the microphone effects, in `pickupNames` order. Only 0x07 (Circles) is known:
    /// 0x00–0x0D and 0x10–0x13 were tried on hardware and did nothing. The ♫ button on the controller
    /// cycles the other sound effects.
    static let pickupCodes: [UInt8] = [0x07]

    static func pickupBody(_ index: Int) -> [UInt8] {
        [Cmd.effect, effectCategoryRhythm, pickupCodes[min(max(index, 0), pickupCodes.count - 1)]]
    }

    /// `speed` 0 (slow) ... 100 (fast). The device byte runs the other way.
    static func speedBody(_ speed: Double) -> [UInt8] {
        [Cmd.speed, UInt8(clamping: 100 - Int(speed.rounded()))]
    }

    // MARK: Per-LED frames

    /// Encodes LED colors as (start, R, G, B, end) ranges with 1-based inclusive indices.
    /// Adjacent identical LEDs always share a range; if more than `maxRanges` remain,
    /// the adjacent pair whose merge adds the least squared color error is joined until it fits.
    static func rangePayload(_ colors: [RGB], maxRanges: Int) -> [UInt8] {
        struct Run { var start: Int; var end: Int; var n: Double; var r: Double; var g: Double; var b: Double }
        let colors = Array(colors.prefix(255))
        var runs: [Run] = []
        runs.reserveCapacity(colors.count)
        for (i, c) in colors.enumerated() {
            let (r, g, b) = (Double(c.r), Double(c.g), Double(c.b))
            if var last = runs.last, last.r / last.n == r, last.g / last.n == g, last.b / last.n == b {
                last.end = i + 1; last.n += 1; last.r += r; last.g += g; last.b += b
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(start: i + 1, end: i + 1, n: 1, r: r, g: g, b: b))
            }
        }

        // Extra squared error from merging two runs = na*nb/(na+nb) * |meanA - meanB|^2
        func mergeCost(_ a: Run, _ b: Run) -> Double {
            let dr = a.r / a.n - b.r / b.n, dg = a.g / a.n - b.g / b.n, db = a.b / a.n - b.b / b.n
            return a.n * b.n / (a.n + b.n) * (dr * dr + dg * dg + db * db)
        }
        let limit = max(1, maxRanges)
        while runs.count > limit {
            var best = 0
            var bestCost = Double.infinity
            for i in 0 ..< runs.count - 1 {
                let cost = mergeCost(runs[i], runs[i + 1])
                if cost < bestCost { bestCost = cost; best = i }
            }
            let b = runs.remove(at: best + 1)
            runs[best].end = b.end; runs[best].n += b.n
            runs[best].r += b.r; runs[best].g += b.g; runs[best].b += b.b
        }

        var out: [UInt8] = []
        out.reserveCapacity(runs.count * 5)
        for run in runs {
            out.append(UInt8(run.start))
            out.append(UInt8((run.r / run.n).rounded()))
            out.append(UInt8((run.g / run.n).rounded()))
            out.append(UInt8((run.b / run.n).rounded()))
            out.append(UInt8(run.end))
        }
        return out
    }

    // MARK: Replies

    static func parseDeviceInfo(_ d: [UInt8]) -> DeviceInfo? {
        guard d.count >= 24, d[0] == 0x52, d[1] == 0x42, d[4] == Cmd.deviceInfo else { return nil }
        let hex = { (s: ArraySlice<UInt8>) in s.map { String(format: "%02x", $0) }.joined() }
        return DeviceInfo(
            id: hex(d[5 ..< 8]),
            sizeInches: Int(d[8]),
            ledCount: Int(d[11]),
            uuid: hex(d[12 ..< 20]),
            firmware: "\(d[21]).\(d[22]).\(d[23])"
        )
    }
}
