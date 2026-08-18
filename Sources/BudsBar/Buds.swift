import Foundation
import IOBluetooth
import Observation

/// Live state of the earbuds plus the Bluetooth plumbing that produces it.
///
/// Two independent links are involved:
///   - the baseband connection (`openConnection`/`closeConnection`), which is what the
///     power toggle in the UI drives, and
///   - the vendor RFCOMM control channel (`oppointeraction`), which carries noise-control
///     and per-bud battery. The latter only exists while the former is up.
@Observable
final class Buds: NSObject, IOBluetoothRFCOMMChannelDelegate {

    // realme Buds T500 Pro. IOBluetooth wants dashes, not colons.
    static let address = "B0-38-E2-DE-E6-16"

    /// SDP service UUID for OPPO/realme's `oppointeraction` control service.
    /// realme is an OPPO sub-brand and shares the protocol.
    private static let controlServiceUUID: [UInt8] = [
        0x00, 0x00, 0x07, 0x9a, 0xd1, 0x02, 0x11, 0xe1,
        0x9b, 0x23, 0x00, 0x02, 0x5b, 0x00, 0xa5, 0xa5,
    ]

    // MARK: - Published state

    var name: String = "realme Buds T500 Pro"
    var isConnected = false
    /// True once the vendor control channel is open — noise control needs it.
    var isControlChannelOpen = false
    var battery = Battery()
    var mode: NoiseMode?
    /// Set while a connect/disconnect is in flight so the toggle can't be double-fired.
    var isBusy = false
    var lastError: String?

    struct Battery {
        var left: Int?
        var right: Int?
        var enclosure: Int?
    }

    // MARK: - Private

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var rxBuffer: [UInt8] = []
    private var disconnectObserver: IOBluetoothUserNotification?

    override init() {
        super.init()
        device = IOBluetoothDevice(addressString: Self.address)
        if let cached = device?.name, !cached.isEmpty { name = cached }

        // Fires for *any* device connecting; we filter to ours. There is no
        // per-device connect notification in IOBluetooth, only a global one.
        IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:)))

        refreshConnectionState()
    }

    // MARK: - Power toggle

    func connect() {
        guard !isBusy, let device else { return }
        isBusy = true
        lastError = nil
        // openConnection blocks until the baseband link is up or times out.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = device.openConnection()
            DispatchQueue.main.async {
                self.isBusy = false
                if result == kIOReturnSuccess {
                    self.refreshConnectionState()
                } else {
                    self.lastError = Self.describe(result)
                }
            }
        }
    }

    func disconnect() {
        guard !isBusy, let device else { return }
        isBusy = true
        closeControlChannel()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = device.closeConnection()
            DispatchQueue.main.async {
                self.isBusy = false
                if result != kIOReturnSuccess { self.lastError = Self.describe(result) }
                self.refreshConnectionState()
            }
        }
    }

    // MARK: - Connection tracking

    @objc private func deviceDidConnect(_ notification: IOBluetoothUserNotification, device connected: IOBluetoothDevice) {
        guard connected.addressString == device?.addressString else { return }
        // Re-register per connection; the disconnect notification is one-shot.
        disconnectObserver = connected.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDidDisconnect(_:device:)))
        DispatchQueue.main.async { self.refreshConnectionState() }
    }

    @objc private func deviceDidDisconnect(_ notification: IOBluetoothUserNotification, device disconnected: IOBluetoothDevice) {
        disconnectObserver = nil
        DispatchQueue.main.async {
            self.closeControlChannel()
            self.refreshConnectionState()
        }
    }

    func refreshConnectionState() {
        let connected = device?.isConnected() ?? false
        isConnected = connected
        if connected {
            openControlChannel()
        } else {
            battery = Battery()
            mode = nil
        }
    }

    // MARK: - Vendor control channel

    private func openControlChannel() {
        guard channel == nil, let device else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            // SDP-resolve the channel rather than hardcoding 15, so a firmware
            // renumber can't silently point us at a different service.
            device.performSDPQuery(nil)
            Thread.sleep(forTimeInterval: 2)

            let uuid = IOBluetoothSDPUUID(bytes: Self.controlServiceUUID, length: 16)
            guard let record = device.getServiceRecord(for: uuid) else {
                DispatchQueue.main.async { self.lastError = "control service not found" }
                return
            }
            var channelID: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
                DispatchQueue.main.async { self.lastError = "control service has no RFCOMM channel" }
                return
            }

            DispatchQueue.main.async {
                var opened: IOBluetoothRFCOMMChannel?
                let result = device.openRFCOMMChannelAsync(
                    &opened, withChannelID: channelID, delegate: self)
                if result == kIOReturnSuccess {
                    self.channel = opened
                } else {
                    // Most likely another host already holds the control channel.
                    self.lastError = "control channel busy (\(Self.describe(result)))"
                }
            }
        }
    }

    private func closeControlChannel() {
        channel?.close()
        channel = nil
        rxBuffer.removeAll()
        isControlChannelOpen = false
    }

    // MARK: - Noise control

    func set(mode requested: NoiseMode) {
        let packet = BudsProtocol.encodeSetNoiseMode(requested)
        // Empty means the write opcode is not known yet — never send a guessed packet.
        guard !packet.isEmpty else { return }
        // Deliberately not updating `mode` here. The buds echo a state notification
        // once they have actually switched, and that echo is what the UI renders —
        // it is also what keeps this panel and realme Link on the phone in agreement.
        send(packet)
    }

    @discardableResult
    private func send(_ packet: [UInt8]) -> Bool {
        guard let channel, isControlChannelOpen else { return false }
        var bytes = packet
        let result = bytes.withUnsafeMutableBytes { raw in
            channel.writeAsync(raw.baseAddress, length: UInt16(raw.count), refcon: nil)
        }
        if result != kIOReturnSuccess {
            lastError = "write failed: \(Self.describe(result))"
            return false
        }
        return true
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else {
            lastError = "control channel open failed (\(Self.describe(error)))"
            self.channel = nil
            return
        }
        isControlChannelOpen = true
        lastError = nil
        if ProcessInfo.processInfo.environment["BUDSBAR_TEST"] != nil {
            // Give the handshake sent below time to land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.startModeTest() }
        }
        for packet in BudsProtocol.handshake() {
            var bytes = packet
            _ = bytes.withUnsafeMutableBytes { raw in
                channel.writeAsync(raw.baseAddress, length: UInt16(raw.count), refcon: nil)
            }
        }
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let chunk = Array(UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))
        rxBuffer.append(contentsOf: chunk)
        // Raw trace on stderr — still the fastest way to work out the bytes we have
        // not decoded yet (the write opcode, the wear-state payload).
        FileHandle.standardError.write(Data("RX \(BudsProtocol.hex(chunk))\n".utf8))

        // RFCOMM delivers arbitrary chunks; frames split across callbacks.
        let frames = BudsProtocol.drainFrames(from: &rxBuffer)
        for frame in frames { apply(frame) }
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        closeControlChannel()
    }

    private func apply(_ frame: BudsProtocol.Frame) {
        for update in BudsProtocol.interpret(frame) {
            switch update {
            case .noiseMode(let value):
                if mode != value {
                    FileHandle.standardError.write(
                        Data("MODE reported \(value.label), wire \(value.wire)\n".utf8))
                }
                mode = value
            case .battery(let left, let right, let enclosure):
                if let left { battery.left = left }
                if let right { battery.right = right }
                if let enclosure { battery.enclosure = enclosure }
            }
        }
    }

    // MARK: - Mode cycle test

    /// Drives all three modes in turn so the command can be verified end to end against
    /// the notifications the buds send back. Runs only under BUDSBAR_TEST=1.
    private var testQueue: [NoiseMode] = []
    private var testTimer: Timer?

    private func startModeTest() {
        guard isControlChannelOpen else { return }
        testQueue = [.noiseCancellation, .transparency, .off]
        testLog("cycling modes, 3s apart")
        testTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let next = self.testQueue.first else {
                self.testLog("mode cycle complete")
                self.testTimer?.invalidate()
                self.testTimer = nil
                return
            }
            self.testQueue.removeFirst()
            self.testLog("commanding \(next.label), value \(next.wire)")
            self.set(mode: next)
        }
    }

    private func testLog(_ message: String) {
        FileHandle.standardError.write(Data("TEST \(message)\n".utf8))
    }

    // MARK: - Errors

    private static func describe(_ code: IOReturn) -> String {
        switch code {
        case kIOReturnSuccess: return "ok"
        case kIOReturnTimeout: return "timed out — buds asleep, in the case, or out of range"
        case kIOReturnNoDevice: return "device not found"
        case kIOReturnBusy: return "busy"
        case kIOReturnExclusiveAccess: return "already in use by another app"
        case kIOReturnNotOpen: return "not open"
        default: return "IOReturn \(code)"
        }
    }
}
