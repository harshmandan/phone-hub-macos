#if canImport(IOBluetooth)
import Foundation
import IOBluetooth
import CryptoKit

/// Nearby Connections over **Bluetooth Classic (RFCOMM)** — the bootstrap medium
/// the phone's Quick Start *Source* flow actually uses (GMS decompile 26.45.31:
/// source discovers over {BLE, BT-Classic}, connects over BT-Classic; Wi-Fi LAN
/// is only a post-bootstrap upgrade). The Mac advertises an SDP service under the
/// Nearby service id and accepts an RFCOMM channel; the phone (given our BT MAC
/// via the injected D2DDevice, or by discovery) opens it, and the same
/// `NearbyConnection` state machine runs on top.
///
/// Framing matches `FrameConnection`: each Nearby frame is a 4-byte big-endian
/// length prefix followed by the OfflineFrame bytes. RFCOMM delivers arbitrary
/// chunks, so inbound bytes are buffered and reassembled.

// MARK: - the Nearby service id → SDP UUID

public enum NearbyBt {
    /// Phenotype `nearby_connections_service_id`, used by Quick Start source+target.
    public static let serviceId = "com.google.android.gms.smartdevice.NC_ID"

    /// Nearby derives the Bluetooth-Classic SDP service UUID from the service id
    /// as a name-based (type-3) UUID: MD5(service_id) with the version nibble set
    /// to 3 and the RFC-4122 variant bits set. Confirmed against google/nearby
    /// `internal/platform/uuid.cc` (`Uuid(absl::string_view)`) and
    /// `bluetooth_classic.cc` (`GenerateUuidFromString(service_id)`).
    /// For NC_ID this computes `5e164731-1999-3405-9061-08a610fd3787`.
    public static func serviceUuidBytes(_ id: String = serviceId) -> [UInt8] {
        var b = [UInt8](Insecure.MD5.hash(data: Data(id.utf8)))
        b[6] = (b[6] & 0x0f) | 0x30   // version 3 (name-based, MD5)
        b[8] = (b[8] & 0x3f) | 0x80   // RFC-4122 variant
        return b
    }

    public static func serviceUuidString(_ id: String = serviceId) -> String {
        let b = serviceUuidBytes(id)
        func hx(_ r: Range<Int>) -> String { b[r].map { String(format: "%02x", $0) }.joined() }
        return "\(hx(0..<4))-\(hx(4..<6))-\(hx(6..<8))-\(hx(8..<10))-\(hx(10..<16))"
    }

    /// The Nearby Connections Bluetooth-Classic advertisement, as the string the
    /// Mac must set as its Bluetooth (Computer) name so a phone's NC inquiry
    /// discovers it. Layout (google/nearby `bluetooth_device_name.cc`):
    /// websafe-b64( [v1<<5 | PCP] + endpoint_id[4] + SHA256(service_id)[:3] +
    ///              fieldByte(0) + 6×0 reserved + len(info) + endpoint_info ).
    /// PCP = 3 (P2P_POINT_TO_POINT), which Quick Start uses.
    public static func btClassicDeviceName(serviceId sid: String = serviceId,
                                           endpointId: String, endpointInfo: Data) -> String {
        let hash = [UInt8](SHA256.hash(data: Data(sid.utf8))).prefix(3)
        var eid = Array(endpointId.utf8)
        while eid.count < 4 { eid.append(0x30) }       // pad to 4 with '0'
        var raw: [UInt8] = [0x20 | 0x03]               // version kV1<<5 | PCP P2P_POINT_TO_POINT
        raw += eid.prefix(4)
        raw += hash
        raw.append(0x00)                               // field byte (WebRTC flag off)
        raw += [UInt8](repeating: 0, count: 6)         // reserved
        let info = [UInt8](endpointInfo.prefix(131))
        raw.append(UInt8(info.count))
        raw += info
        return Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - FrameChannel over an open RFCOMM channel

public final class RfcommFrameChannel: NSObject, FrameChannel, IOBluetoothRFCOMMChannelDelegate {
    private let channel: IOBluetoothRFCOMMChannel
    private var inBuffer = Data()
    private var pending: [(Data?) -> Void] = []   // FIFO receiveFrame callbacks
    private let lock = NSLock()
    private var closed = false

    public init(_ channel: IOBluetoothRFCOMMChannel) {
        self.channel = channel
        super.init()
        channel.setDelegate(self)
    }

    public func start() {}                 // channel is already open
    public func cancel() { channel.close() }

    public func sendFrame(_ frame: Data, completion: (() -> Void)? = nil) {
        var be = UInt32(frame.count).bigEndian
        var out = withUnsafeBytes(of: &be) { Data($0) } + frame
        let mtu = Int(channel.getMTU())
        let total = out.count
        let chunk = mtu > 0 ? mtu : total
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < total {
                let n = min(chunk, total - off)
                _ = channel.writeSync(base + off, length: UInt16(n))
                off += n
            }
        }
        completion?()
    }

    public func receiveFrame(_ callback: @escaping (Data?) -> Void) {
        lock.lock()
        if closed { lock.unlock(); callback(nil); return }
        pending.append(callback)
        lock.unlock()
        drain()
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty, inBuffer.count >= 4 else { lock.unlock(); return }
            let h = [UInt8](inBuffer.prefix(4))
            let n = Int(UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3]))
            guard inBuffer.count >= 4 + n else { lock.unlock(); return }
            let frame = Data(inBuffer.dropFirst(4).prefix(n))
            inBuffer.removeFirst(4 + n)
            let cb = pending.removeFirst()
            lock.unlock()
            cb(frame)
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate
    public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                  data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        if dataLength > 0 { inBuffer.append(Data(bytes: dataPointer, count: dataLength)) }
        drain()
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        lock.lock()
        closed = true
        let cbs = pending; pending.removeAll()
        lock.unlock()
        cbs.forEach { $0(nil) }
    }
}

// MARK: - the RFCOMM server (publish SDP + accept channels)

public final class RfcommNearbyServer: NSObject {
    private let name: String
    private let channelID: BluetoothRFCOMMChannelID
    // Fixed test bootstrap so the C6 beacon and btserve share the SAME 6-byte
    // advertising id: the beacon emits these raw bytes, we advertise base64url of
    // them. Keep in sync with ADVERTISING_ID in firmware/chromebook_beacon.
    private let bootstrap = QuickStart.Bootstrap(
        advertisingId: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]),
        sharedSecret: Data(repeating: 0x5a, count: 32))
    private var serviceRecord: IOBluetoothSDPServiceRecord?
    private var openNote: IOBluetoothUserNotification?
    private var channels: [RfcommFrameChannel] = []
    private var connections: [NearbyConnection] = []

    public init(name: String, channelID: BluetoothRFCOMMChannelID = 3) {
        self.name = name
        self.channelID = channelID
        super.init()
    }

    /// Build the SDP service dictionary: ServiceClassIDList = our 128-bit UUID,
    /// ProtocolDescriptorList = L2CAP + RFCOMM(channel), plus a service name.
    private func serviceDict() -> [String: Any] {
        var uu = NearbyBt.serviceUuidBytes()
        let uuid = IOBluetoothSDPUUID(bytes: &uu, length: uu.count)

        let l2cap = IOBluetoothSDPUUID(uuid16: UInt16(kBluetoothSDPUUID16L2CAP))
        let rfcomm = IOBluetoothSDPUUID(uuid16: UInt16(kBluetoothSDPUUID16RFCOMM))

        let rfcommChannelElement: [String: Any] = [
            "DataElementType": 1,            // unsigned int
            "DataElementSize": 1,            // 1 byte
            "DataElementValue": Int(channelID),
        ]

        return [
            "0001 - ServiceClassIDList": [uuid as Any],
            "0004 - ProtocolDescriptorList": [
                [l2cap as Any],
                [rfcomm as Any, rfcommChannelElement],
            ],
            "0100 - ServiceName*": name,
        ]
    }

    public func run(seconds: Double) {
        setvbuf(stdout, nil, _IONBF, 0)
        print("RFCOMM Nearby server — service \(NearbyBt.serviceId)")
        print("  SDP UUID \(NearbyBt.serviceUuidString())  RFCOMM channel \(channelID)")

        if let ctrl = IOBluetoothHostController.default() {
            print("  this Mac BT address: \(ctrl.addressAsString() ?? "?")  (→ D2DDevice.bluetoothMacAddr)")
        } else {
            print("  (!) no default Bluetooth host controller")
        }
        // Values for the injected ConnectionRequest (adb am start):
        print("  advertising_id:  \(bootstrap.advertisingId.base64url.replacingOccurrences(of: "=", with: ""))")
        print("  outOfBandKey:    \(bootstrap.sharedSecret.base64EncodedString())")

        // Path A — Bluetooth-Classic discovery: the phone's Quick Start inquiry
        // finds the Mac by its Bluetooth (Computer) name. Set it to this NC name.
        let eid = String((0..<4).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! })
        // Fixed short label — NOT self.name (which is the computer name, i.e. this
        // very NC string → a feedback loop that bloats the advertisement each run).
        let info = NearbyAdvertiser.quickStartEndpointInfo(name: "Chromebook", advertisingId: bootstrap.advertisingId)
        let btName = NearbyBt.btClassicDeviceName(endpointId: eid, endpointInfo: info)
        print("  --- path A (Bluetooth-Classic discovery) ---")
        print("  1) make the Mac discoverable with this name (reversible):")
        print("     sudo scutil --set ComputerName '\(btName)'")
        print("  2) open System Settings ▸ Bluetooth (keeps the Mac inquiry-discoverable)")
        print("  3) run this to trigger the phone, then click the Bluetooth window and hold focus ~20s:")
        print("     adb shell \"am start -a android.intent.action.VIEW -d '\(QuickStart.qrURL(bootstrap))'\"")

        print("  publishing SDP service record…")
        serviceRecord = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: serviceDict())
        print("  SDP record: \(serviceRecord == nil ? "FAILED" : "published")")

        print("  registering for incoming RFCOMM on channel \(channelID)…")
        openNote = IOBluetoothRFCOMMChannel.register(
            forChannelOpenNotifications: self,
            selector: #selector(channelOpened(_:channel:)),
            withChannelID: channelID,
            direction: kIOBluetoothUserNotificationChannelDirectionIncoming)
        print("  open-notification: \(openNote == nil ? "FAILED" : "registered")")
        print("  waiting \(Int(seconds))s for the phone to open the channel…")

        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        openNote?.unregister()
        serviceRecord = nil
        print("RFCOMM server done")
    }

    @objc private func channelOpened(_ note: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        guard channel.isIncoming() else { return }
        let dev = channel.getDevice()?.addressString ?? "?"
        print("!! phone opened RFCOMM channel from \(dev)")
        let fc = RfcommFrameChannel(channel)
        let nearby = NearbyConnection(fc, quickStartSecret: bootstrap.sharedSecret)
        channels.append(fc)
        connections.append(nearby)
        nearby.start()
    }
}
#endif
