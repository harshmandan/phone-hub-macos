#if canImport(IOBluetooth)
import Foundation
import CryptoKit
import IOBluetooth

/// Phone Hub connection — the Mac as the Nearby Connections INITIATOR. We open an
/// out-of-band RFCOMM channel to the phone's "secure_channel" service, then run
/// the Nearby handshake as the client (the mirror of NearbyConnection's responder
/// flow): ConnectionRequest → UKEY2 ClientInit → (ServerInit) → ClientFinished →
/// ConnectionResponse → encrypted D2D channel. After the channel is up, the phone
/// runs SecureChannel auth and sends a PhoneStatusSnapshot; for now we log every
/// frame so a live run shows the real sequence.
public final class PhoneHubClient: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var fc: RfcommFrameChannel?
    private let ukey = Ukey2.Client()
    private var channel: SecureContext?
    private var opened = false

    enum State { case connecting, sentClientInit, deriving, secure }
    private var state: State = .connecting

    public func run(mac: String, channelID: Int, seconds: Double) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let device = IOBluetoothDevice(addressString: mac) else { print("bad mac"); return }
        print("opening RFCOMM to \(mac) channel \(channelID) …")
        print("  connected=\(device.isConnected()) paired=\(device.isPaired())")
        if !device.isConnected() {
            let oc = device.openConnection()
            print("  openConnection → \(oc) (connected=\(device.isConnected()))")
        }
        // Re-resolve the secure_channel RFCOMM channel from SDP each time — Android
        // reassigns it per advertising window, so a cached number (13) goes stale.
        var chan = BluetoothRFCOMMChannelID(channelID)
        device.performSDPQuery(self)
        let deadline = Date().addingTimeInterval(8)
        while !sdpDone && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        if let resolved = secureChannelRfcomm(device) {
            print("  SDP resolved secure_channel → RFCOMM channel \(resolved)")
            chan = resolved
        } else {
            print("  SDP did not list secure_channel; trying channel \(chan) anyway")
        }
        // Async open: the delegate's rfcommChannelOpenComplete reports the real
        // status (sync open collapses accept-then-drop into a generic error).
        var ch: IOBluetoothRFCOMMChannel?
        let rc = device.openRFCOMMChannelAsync(&ch, withChannelID: chan, delegate: self)
        print("  openRFCOMMChannelAsync kicked off → \(rc) (0x\(String(format: "%08x", UInt32(bitPattern: Int32(rc)))))")
        if rc != kIOReturnSuccess { print("could not start open"); return }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print("done")
    }

    // IOBluetoothRFCOMMChannelDelegate: fires when the async open settles.
    public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        print("rfcommChannelOpenComplete status=\(error) (0x\(String(format: "%08x", UInt32(bitPattern: Int32(error)))))")
        guard error == kIOReturnSuccess else { print("open rejected by phone"); return }
        print("RFCOMM channel open ✅")
        let fc = RfcommFrameChannel(rfcommChannel)   // re-sets itself as delegate
        self.fc = fc
        fc.start()
        startHandshake()
        receiveLoop()
    }

    private var sdpDone = false
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { sdpDone = true }

    /// The RFCOMM channel of the phone's secure_channel SDP record, if present.
    private func secureChannelRfcomm(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let want = NearbyBt.serviceUuidString("secure_channel").lowercased()
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else { return nil }
        for rec in services {
            var uuids: [String] = []
            if let attrs = rec.attributes as? [NSNumber: IOBluetoothSDPDataElement] {
                for (_, el) in attrs { collectUuids(el, into: &uuids) }
            }
            guard uuids.contains(where: { $0.lowercased().contains("a384bd4f") || $0.lowercased().contains(want) }) else { continue }
            var ch: BluetoothRFCOMMChannelID = 0
            if rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess { return ch }
        }
        return nil
    }

    private func collectUuids(_ el: IOBluetoothSDPDataElement, into out: inout [String]) {
        if let uuid = el.getUUIDValue() { out.append(uuid.description.replacingOccurrences(of: " ", with: "")) }
        if let arr = el.getArrayValue() as? [IOBluetoothSDPDataElement] { for e in arr { collectUuids(e, into: &out) } }
    }

    private func log(_ s: String) { print("  [phonehub] \(s)") }

    private func startHandshake() {
        guard let fc else { return }
        // Nearby initiator: ConnectionRequest, then UKEY2 ClientInit.
        let info = Data([0x01]) + Data("Chromebook\u{0}".utf8)   // minimal endpoint info
        let nonce = Int32(bitPattern: UInt32.random(in: 0...UInt32.max))
        fc.sendFrame(NearbyFrames.connectionRequest(endpointId: "CROS", endpointInfo: info, nonce: nonce))
        log("→ ConnectionRequest (endpoint CROS)")
        let ci = ukey.clientInit()
        fc.sendFrame(ci)
        log("→ UKEY2 ClientInit (\(ci.count)B)")
        state = .sentClientInit
    }

    private func receiveLoop() {
        fc?.receiveFrame { [weak self] data in
            guard let self else { return }
            guard let data else { self.log("connection closed"); return }
            do { try self.process(data) } catch { self.log("error: \(error)") }
            self.receiveLoop()
        }
    }

    private func process(_ data: Data) throws {
        switch state {
        case .connecting, .sentClientInit:
            // Expect UKEY2 ServerInit (raw UKEY2 message). The phone may first send
            // its own plaintext OfflineFrame(s); log + skip anything that isn't it.
            let fields = Pb.readFields(data)
            if fields.varint(1) == Ukey2.typeServerInit {
                let (clientFinished, derived) = try ukey.handleServerInit(data)
                fc?.sendFrame(clientFinished)
                log("← ServerInit (\(data.count)B); → ClientFinished; auth \(derived.authString.prefix(4).hex)…")
                let salt = Data(SessionKeys.salt)
                let d2dClient = Ukey2.hkdf(derived.nextSecret, salt: salt, info: Data("client".utf8), length: 32)
                let d2dServer = Ukey2.hkdf(derived.nextSecret, salt: salt, info: Data("server".utf8), length: 32)
                let ch = SecureContext(encodeKey: d2dClient, decodeKey: d2dServer)  // we are the client
                ch.lenientSequence = true
                channel = ch
                // Initiator sends ConnectionResponse(accept) next.
                fc?.sendFrame(NearbyFrames.connectionResponse(accept: true))
                log("→ ConnectionResponse(accept); channel keyed")
                state = .deriving
            } else {
                let t = NearbyFrames.frameType(data)
                log("← plaintext frame type \(t.map(String.init) ?? "?") (\(data.count)B): \(data.prefix(48).hex) — skipped")
            }

        case .deriving:
            // The phone's plaintext ConnectionResponse, then encryption begins.
            let t = NearbyFrames.frameType(data)
            if t == 2 {
                log("← phone ConnectionResponse — secure channel up ✅")
                state = .secure
            } else {
                log("← (deriving) frame type \(t.map(String.init) ?? "?") (\(data.count)B) \(data.prefix(32).hex)")
            }

        case .secure:
            guard let ch = channel else { return }
            let plain: Data
            do { plain = try ch.decode(data) } catch {
                log("← non-decryptable \(data.count)B \(data.prefix(32).hex) (\(error))"); return
            }
            let t = NearbyFrames.frameType(plain)
            if t == NearbyFrames.framePayloadTransfer, let (id, body, last) = NearbyFrames.payloadBody(plain) {
                log("← 🔓 payload id=\(id) last=\(last) \(body.count)B: \(body.prefix(80).hex)")
                if let s = String(data: body.prefix(200), encoding: .utf8) { log("     utf8: \(s)") }
            } else {
                log("← 🔓 frame type \(t.map(String.init) ?? "?") (\(plain.count)B) \(plain.prefix(48).hex)")
            }
        }
    }
}
#endif
