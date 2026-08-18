import Foundation

enum NoiseMode: String, CaseIterable, Identifiable {
    case noiseCancellation
    case off
    case transparency

    var id: String { rawValue }

    var label: String {
        switch self {
        case .noiseCancellation: return "ANC"
        case .off: return "Off"
        case .transparency: return "Transparency"
        }
    }

    var symbol: String {
        switch self {
        case .noiseCancellation: return "person.crop.circle"
        case .off: return "person.crop.circle.fill"
        case .transparency: return "person.crop.circle.badge.questionmark"
        }
    }

    /// OPOv1 numbers the modes as one bit each, and the buds use the same values when
    /// commanded and when reporting.
    ///
    /// ANC and Off are the reverse of what the published OnePlus mapping says — on this
    /// hardware 0x01 is Off and 0x04 is ANC, confirmed by listening to what each command
    /// actually does. Consistent with the capture: while cycling modes from the phone the
    /// buds only ever announced 0x01, 0x02 and 0x08, never 0x04.
    init?(wire: UInt8) {
        switch wire {
        case 0x01: self = .off
        case 0x02: self = .transparency
        case 0x04, 0x08: self = .noiseCancellation
        default: return nil
        }
    }

    var wire: UInt8 {
        switch self {
        case .off: return 0x01
        case .transparency: return 0x02
        case .noiseCancellation: return 0x04
        }
    }
}

/// Wire format for the `oppointeraction` RFCOMM channel on realme/OPPO earbuds.
///
/// Pure functions over bytes — no I/O — so `selfCheck()` can exercise them against
/// recorded traffic without the hardware present.
///
///     aa <len> <b2> <b3> <opcode:u16be> <seq> <payloadLen:u16le> <payload…>
///
/// `len` counts every byte after itself, so a frame is `len + 2` bytes long. There is no
/// trailing checksum — the length accounts for the payload exactly.
///
/// The payload is a tagged list: `<type> <count>` followed by `count` (id, value) pairs.
enum BudsProtocol {

    static let sync: UInt8 = 0xaa
    /// The only opcode observed: an unsolicited device status report.
    static let opcodeStatusReport: UInt16 = 0x0402

    struct Frame {
        var opcode: UInt16
        var sequence: UInt8
        var payload: [UInt8]
        var raw: [UInt8]
    }

    enum Update: Equatable {
        case noiseMode(NoiseMode)
        case battery(left: Int?, right: Int?, enclosure: Int?)
    }

    // MARK: - Payload types

    private enum PayloadType: UInt8 {
        case battery = 0x01
        /// Ids 0x01–0x03, none of which track the noise mode. Not decoded.
        case otherSettings = 0x02
        case noiseMode = 0x03
    }

    private enum BatteryID: UInt8 {
        case left = 0x01
        case right = 0x02
        case enclosure = 0x03
    }

    /// Entry id carrying the mode inside a `noiseMode` payload.
    private static let noiseModeID: UInt8 = 0x01

    // MARK: - Sending

    /// Packets to send once the channel opens. Status arrives unprompted, but OPOv1
    /// expects a hello before it will accept commands.
    static func handshake() -> [[UInt8]] { [encodeHello()] }

    /// Builds a frame, filling in both length fields.
    static func makeFrame(_ b2: UInt8, _ b3: UInt8, _ b4: UInt8, _ b5: UInt8,
                          sequence: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [sync, 0, b2, b3, b4, b5, sequence,
                              UInt8(payload.count & 0xff), UInt8(payload.count >> 8)]
        frame += payload
        frame[1] = UInt8(frame.count - 2)     // len counts every byte after itself
        return frame
    }

    /// OPOv1 categories. The buds' status notifications arrive on `.status`.
    enum Category: UInt8 {
        case system = 0x00
        case status = 0x04
    }

    /// Subcommands within a category.
    private enum Subcommand: UInt8 {
        case hello = 0x01
        case setNoiseMode = 0x04
    }

    static func encodeSetNoiseMode(_ mode: NoiseMode) -> [UInt8] {
        makeFrame(0x00, 0x00, Category.status.rawValue, Subcommand.setNoiseMode.rawValue,
                  sequence: nextSequence(),
                  payload: [0x01, 0x01, mode.wire])
    }

    /// Session opener. The buds answer it, and OPOv1 wants it before commands.
    static func encodeHello() -> [UInt8] {
        makeFrame(0x00, 0x00, Category.system.rawValue, Subcommand.hello.rawValue,
                  sequence: nextSequence(), payload: [])
    }

    private static var sequenceCounter: UInt8 = 0

    static func nextSequence() -> UInt8 {
        sequenceCounter &+= 1
        return sequenceCounter
    }

    // MARK: - Receiving

    /// Pulls every complete frame out of `buffer`, leaving any partial tail behind.
    /// RFCOMM delivers arbitrary chunks, so frames both split and coalesce.
    static func drainFrames(from buffer: inout [UInt8]) -> [Frame] {
        var frames: [Frame] = []

        while true {
            // Resynchronise: drop anything before the next sync byte.
            guard let start = buffer.firstIndex(of: sync) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }

            guard buffer.count >= 2 else { break }
            let total = Int(buffer[1]) + 2
            guard total >= 9 else {
                // Not a plausible frame — drop the sync byte and look for the next one.
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { break }   // wait for the rest

            let raw = Array(buffer[0..<total])
            let payloadLength = Int(raw[7]) | Int(raw[8]) << 8
            if 9 + payloadLength == total {
                frames.append(Frame(
                    opcode: UInt16(raw[4]) << 8 | UInt16(raw[5]),
                    sequence: raw[6],
                    payload: Array(raw[9..<total]),
                    raw: raw))
                buffer.removeFirst(total)
            } else {
                // Length fields disagree: this was not a frame boundary after all.
                buffer.removeFirst()
            }
        }

        return frames
    }

    static func interpret(_ frame: Frame) -> [Update] {
        guard frame.opcode == opcodeStatusReport else { return [] }

        let payload = frame.payload
        guard payload.count >= 2, let type = PayloadType(rawValue: payload[0]) else { return [] }

        let count = Int(payload[1])
        var pairs: [(UInt8, UInt8)] = []
        var index = 2
        for _ in 0..<count {
            guard index + 1 < payload.count else { break }
            pairs.append((payload[index], payload[index + 1]))
            index += 2
        }

        switch type {
        case .battery:
            var left: Int?, right: Int?, enclosure: Int?
            for (id, value) in pairs {
                switch BatteryID(rawValue: id) {
                case .left: left = Int(value)
                case .right: right = Int(value)
                case .enclosure:
                    // The case reports 0 when it is asleep or shut rather than omitting
                    // itself, and a genuinely flat case is the rarer reading — so treat
                    // 0 as "unknown" and show a dash instead of a false 0%.
                    enclosure = value == 0 ? nil : Int(value)
                case nil: break
                }
            }
            return [.battery(left: left, right: right, enclosure: enclosure)]

        case .noiseMode:
            for (id, value) in pairs where id == noiseModeID {
                if let mode = NoiseMode(wire: value) { return [.noiseMode(mode)] }
            }
            return []

        case .otherSettings:
            return []
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: - Self check

    /// Replays real captured frames. Runs at launch in debug builds.
    static func selfCheck() {
        func bytes(_ string: String) -> [UInt8] {
            string.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        }

        // Battery report captured while both buds read 100% and the case read 80%.
        var buffer = bytes("aa 0f 00 00 04 02 0c 08 00 01 03 01 64 02 64 03 50")
        var frames = drainFrames(from: &buffer)
        assert(frames.count == 1, "one battery frame")
        assert(buffer.isEmpty, "buffer fully consumed")
        assert(frames[0].opcode == opcodeStatusReport)
        assert(interpret(frames[0]) == [.battery(left: 100, right: 100, enclosure: 80)])

        // Same report with the case asleep — must read as unknown, not 0%.
        buffer = bytes("aa 0f 00 00 04 02 10 08 00 01 03 01 64 02 64 03 00")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]) == [.battery(left: 100, right: 100, enclosure: nil)])

        // Noise mode, captured while commanding each mode in turn.
        for (wire, expected) in [("01", NoiseMode.off),
                                 ("02", .transparency),
                                 ("04", .noiseCancellation),
                                 ("08", .noiseCancellation)] {
            buffer = bytes("aa 0b 00 00 04 02 9b 04 00 03 01 01 \(wire)")
            frames = drainFrames(from: &buffer)
            assert(interpret(frames[0]) == [.noiseMode(expected)], "wire \(wire)")
        }

        // An unmapped mode value yields no update rather than a wrong one.
        buffer = bytes("aa 0b 00 00 04 02 1a 04 00 03 01 01 7f")
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && buffer.isEmpty, "short frame")
        assert(interpret(frames[0]).isEmpty, "unknown mode value ignored")

        // The 0x02 block is a different setting and must not move the mode.
        buffer = bytes("aa 0f 00 00 04 02 0d 08 00 02 03 01 03 02 00 03 04")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]).isEmpty, "0x02 block is not the mode")

        // The frame we send to set a mode must be well formed, carry the set opcode
        // rather than the report opcode, and put the right value in the payload.
        var sent = encodeSetNoiseMode(.transparency)
        assert(sent == bytes("aa 0a 00 00 04 04 \(String(format: "%02x", sent[6])) 03 00 01 01 02"),
               "set frame layout: \(hex(sent))")
        frames = drainFrames(from: &sent)
        assert(frames.count == 1 && sent.isEmpty, "set frame parses as one frame")
        assert(frames[0].opcode == 0x0404, "set uses the set opcode, not the report one")
        assert(interpret(frames[0]).isEmpty, "a set frame is not a status update")

        // Two frames arriving coalesced in one read.
        buffer = bytes("aa 0b 00 00 04 02 1a 04 00 03 01 01 08")
             + bytes("aa 0f 00 00 04 02 0c 08 00 01 03 01 64 02 64 03 50")
        frames = drainFrames(from: &buffer)
        assert(frames.count == 2 && buffer.isEmpty, "coalesced frames")

        // One frame split across two reads: the tail must be held, not misparsed.
        let whole = bytes("aa 0f 00 00 04 02 0c 08 00 01 03 01 64 02 64 03 50")
        buffer = Array(whole[0..<6])
        assert(drainFrames(from: &buffer).isEmpty, "partial frame withheld")
        buffer.append(contentsOf: whole[6...])
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && buffer.isEmpty, "frame completed across reads")
        assert(interpret(frames[0]) == [.battery(left: 100, right: 100, enclosure: 80)])

        // Leading garbage before the sync byte must be skipped, not fatal.
        buffer = bytes("ff ff") + whole
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && buffer.isEmpty, "resynchronised past garbage")

        FileHandle.standardError.write(Data("BudsProtocol.selfCheck passed\n".utf8))
    }
}
