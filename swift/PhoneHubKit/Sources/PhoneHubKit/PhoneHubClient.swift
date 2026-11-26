#if canImport(IOBluetooth)
import Foundation
import CryptoKit
import IOBluetooth

/// Phone Hub connection — the Mac as the Nearby Connections INITIATOR. Phone Hub
/// does NOT ride the BLE weave channel that EasyUnlock / Instant Tethering use;
/// the phone registers its phone_hub message-processor on a SEPARATE Nearby
/// Connections link (phone-side logcat: `Role{featureName=phone_hub,
/// connectionMode=768}` + "starting Nearby Phone Hub advertising"). So we reach
/// it over Nearby Connections instead of weave.
///
/// Two stacked secure layers:
///   Layer 1 (Nearby Connections, UKEY2): we open an out-of-band RFCOMM channel
///     to the phone's "secure_channel" service, then run NC as the CLIENT —
///     ConnectionRequest → UKEY2 ClientInit/ServerInit/ClientFinished →
///     ConnectionResponse → an AES-256-CBC+HMAC channel (`SecureContext`).
///   Layer 2 (secure_channel D2D): the SAME DeviceToDevice auth + WireMessage
///     feature framing as the BLE medium, carried inside Nearby BYTES payloads
///     (confirmed by Chromium: NearbyConnection subclasses the same `Connection`
///     base as the weave medium, so SecureChannel double-auths over NC's UKEY2).
///
/// Sources:
///   service_id "secure_channel": chromeos/ash/services/secure_channel/public/
///     mojom/nearby_connector.mojom (kServiceId)
///   out-of-band BT discovery (bluetooth=true, ble=false, inject phone MAC):
///     chrome/browser/ash/secure_channel/nearby_endpoint_finder_impl.cc
///   RequestConnection + BYTES payloads: chrome/browser/ash/secure_channel/
///     nearby_connection_broker_impl.cc
///   discoverer = UKEY2 client: github.com/google/nearby connections/
///     implementation/base_pcp_handler.cc (encryption_runner_.StartClient)
///   RFCOMM UUID = MD5(v3) of the service_id: internal/platform/uuid.cc
public final class PhoneHubClient: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var fc: RfcommFrameChannel?
    private let ukey = Ukey2.Client()
    private var nearby: SecureContext?             // layer 1 (Nearby UKEY2 channel)

    // RFCOMM open state. The phone ROTATES its secure_channel RFCOMM server
    // channel, so an SDP-resolved channel can already be stale by the time we
    // open it — the phone then accepts the ACL but never completes the RFCOMM
    // open (a silent hang). We bound each open with a timeout and retry with a
    // freshly re-resolved channel.
    private var device: IOBluetoothDevice?
    private var openChannel: IOBluetoothRFCOMMChannel?
    private var openTimer: Timer?
    private var openAttempts = 0
    private var opened = false                     // latches on the first successful open
    private let maxOpenAttempts = 5
    private let openTimeout: TimeInterval = 10
    private var fallbackChannelID = 10

    // Layer 2: secure_channel DeviceToDevice auth over the Nearby channel.
    private let handshake: D2D.Handshake
    private var ctx: D2D.SecureContext?
    private var helloSent = false

    // Nearby BYTES payload reassembly + outgoing id.
    private var pending: [Int64: Data] = [:]
    private var payloadId: Int64 = Int64.random(in: 1...Int64.max)
    // Cap total in-flight reassembly so a payload whose last chunk never arrives
    // (or a hostile stream) can't exhaust memory. A camera-roll photo is a few MB.
    private let maxReassembly = 64 * 1024 * 1024

    // Phone Hub registers its processor shortly AFTER auth, so a lone CrosState
    // can race it; retry on a timer until a phone_hub reply arrives.
    private var crosStateTimer: Timer?
    private var gotPhoneHub = false

    enum State { case connecting, sentClientInit, deriving, secure }
    private var state: State = .connecting

    public var onMessage: ((Data) -> Void)?
    /// Called with each decoded Phone Hub status snapshot/update (battery, signal,
    /// notifications). Lets a caller act on it — e.g. reply to a notification.
    public var onSnapshot: ((PhoneHub.Snapshot) -> Void)?
    /// Called with the phone's recent camera-roll items (metadata + thumbnails).
    public var onPhotos: (([PhoneHub.Photo]) -> Void)?
    /// When true, enable camera_roll in CrosState and fetch recent photos after the
    /// first status snapshot; thumbnails are written to `photoDir`.
    public var fetchPhotos = false
    /// When true (implies fetchPhotos), also download the full-resolution files.
    public var downloadPhotos = false
    /// Where thumbnails and downloaded files are written. Defaults to a per-user,
    /// owner-only directory (not world-readable /tmp).
    public var photoDir = PhoneHubClient.defaultPhotoDir

    /// `~/Library/Application Support/PhoneHub/photos` — per-user, not shared like
    /// /tmp. The directory is created 0700 and files 0600 (see `ensurePhotoDir`).
    public static var defaultPhotoDir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PhoneHub/photos").path
    }

    /// Create `photoDir` owner-only, and tighten it if it already existed looser.
    private func ensurePhotoDir() {
        try? FileManager.default.createDirectory(atPath: photoDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: photoDir)
    }

    /// Write `data` to `path` and restrict it to owner read/write.
    private func writeSecure(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    private var sentPhotoFetch = false
    private var photoByKey: [String: PhoneHub.Photo] = [:]
    private var pendingFiles: [Int64: PhoneHub.Photo] = [:]   // Nearby payload id → photo

    /// D2D auth inputs: our long-term device private key (DeviceSync:BetterTogether
    /// PEM) + the phone's long-term public key (generic-public-key bytes from its
    /// decrypted metadata) — the same pair the BLE medium uses.
    public init(ourLongTermPrivatePem: String, phoneLongTermPublicGeneric: Data) throws {
        let priv = try P256.KeyAgreement.PrivateKey(pemRepresentation: ourLongTermPrivatePem)
        let pub = try SecureMessage.parseGenericPublicKey(phoneLongTermPublicGeneric)
        self.handshake = try D2D.Handshake(ourLongTermPrivate: priv, phoneLongTermPublic: pub)
        super.init()
    }

    /// Blocking: open the connection and run the run loop for `seconds`.
    public func run(mac: String, channelID: Int, seconds: Double) {
        begin(mac: mac, channelID: channelID)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        crosStateTimer?.invalidate()
        print("phonehub done")
    }

    /// Non-blocking: open the RFCOMM channel and drive the handshake via delegate
    /// callbacks on the current run loop. Use when another component (e.g. BleRadio)
    /// owns the run loop — call this from BleRadio.onAuthenticated.
    public func begin(mac: String, channelID: Int) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let device = IOBluetoothDevice(addressString: mac) else { print("bad mac"); return }
        self.device = device
        self.fallbackChannelID = channelID
        log("opening RFCOMM to \(mac) …  connected=\(device.isConnected()) paired=\(device.isPaired())")
        if !device.isConnected() {
            let oc = device.openConnection()
            log("openConnection → \(oc) (connected=\(device.isConnected()))")
        }
        resolveAndOpen()
    }

    /// Re-resolve the CURRENT secure_channel RFCOMM channel from SDP and open it.
    /// Android reassigns this channel per advertising window, so each attempt must
    /// re-query SDP rather than reuse a cached number.
    private func resolveAndOpen() {
        guard let device else { return }
        openAttempts += 1
        var chan = BluetoothRFCOMMChannelID(fallbackChannelID)
        sdpDone = false
        device.performSDPQuery(self)
        let deadline = Date().addingTimeInterval(8)
        while !sdpDone && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        if let resolved = secureChannelRfcomm(device) {
            log("SDP resolved secure_channel → RFCOMM channel \(resolved) (attempt \(openAttempts)/\(maxOpenAttempts))")
            chan = resolved
        } else {
            log("SDP did not list secure_channel; trying channel \(chan) (attempt \(openAttempts)/\(maxOpenAttempts))")
        }
        var ch: IOBluetoothRFCOMMChannel?
        let rc = device.openRFCOMMChannelAsync(&ch, withChannelID: chan, delegate: self)
        openChannel = ch
        log("openRFCOMMChannelAsync → \(rc) (0x\(String(format: "%08x", UInt32(bitPattern: Int32(rc)))))")
        if rc != kIOReturnSuccess { retryOpenOrGiveUp("openRFCOMMChannelAsync failed (\(rc))"); return }
        armOpenTimeout()
    }

    /// If the open doesn't complete in time (stale/rotated channel: the phone
    /// accepts the ACL but has no server socket on that channel), retry with a
    /// freshly re-resolved channel. We do NOT close the pending channel here — a
    /// slow-but-live open can still complete, and `rfcommChannelOpenComplete`
    /// adopts the first success and closes any later duplicate.
    private func armOpenTimeout() {
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: openTimeout, repeats: false) { [weak self] _ in
            guard let self, !self.opened else { return }
            self.log("RFCOMM open stalled \(Int(self.openTimeout))s — stale/rotated channel; re-resolving")
            self.retryOpenOrGiveUp("open timed out")
        }
    }

    private func retryOpenOrGiveUp(_ reason: String) {
        openTimer?.invalidate(); openTimer = nil
        guard !opened else { return }
        guard openAttempts < maxOpenAttempts else {
            log("giving up after \(openAttempts) RFCOMM open attempts (\(reason))")
            return
        }
        // Brief delay so the phone's listener/SDP can settle between rotations.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, !self.opened else { return }
            self.resolveAndOpen()
        }
    }

    public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        // We may have re-opened on a rotated channel while an earlier (slow) open
        // was still pending. Adopt the FIRST success; close any later duplicate so
        // we never run two handshakes on one connection.
        if opened {
            if error == kIOReturnSuccess { rfcommChannel?.close() }
            return
        }
        log("rfcommChannelOpenComplete status=\(error) (0x\(String(format: "%08x", UInt32(bitPattern: Int32(error)))))")
        guard error == kIOReturnSuccess else { log("open attempt rejected by phone"); retryOpenOrGiveUp("open rejected (\(error))"); return }
        opened = true
        openTimer?.invalidate(); openTimer = nil
        log("RFCOMM channel open ✅")
        let fc = RfcommFrameChannel(rfcommChannel)
        self.fc = fc
        fc.start()
        startHandshake()
        receiveLoop()
    }

    private var sdpDone = false
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { sdpDone = true }

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

    // MARK: Nearby Connections layer (layer 1)

    private func startHandshake() {
        guard let fc else { return }
        let info = Data([0x01]) + Data("Chromebook\u{0}".utf8)   // local endpoint_info
        let nonce = Int32(bitPattern: UInt32.random(in: 0...UInt32.max))
        // Random 4-char endpoint_id (like real NC) — a fixed id collides with a
        // stale endpoint on the phone across reconnects.
        let eid = String((0..<4).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })
        fc.sendFrame(NearbyFrames.connectionRequest(endpointId: eid, endpointInfo: info, nonce: nonce,
                                                    medium: NearbyFrames.mediumBluetooth))
        let ci = ukey.clientInit()
        fc.sendFrame(ci)
        log("→ ConnectionRequest(BLUETOOTH) + UKEY2 ClientInit (\(ci.count)B)")
        state = .sentClientInit
    }

    /// Send an app message as an encrypted Nearby BYTES payload (data chunk +
    /// empty last chunk), the two-frame pattern GMS expects.
    private func sendApp(_ body: Data, label: String) {
        guard let fc, let n = nearby else { return }
        let pid = payloadId; payloadId += 1
        fc.sendFrame(n.encode(NearbyFrames.payloadBytes(id: pid, body: body, lastChunk: false)))
        fc.sendFrame(n.encode(NearbyFrames.payloadBytes(id: pid, body: Data(), lastChunk: true,
                                                        totalSize: body.count, offset: body.count)))
        log("→ \(label) (\(body.count)B) as payload \(pid)")
    }

    /// Wrap a secure-channel payload in a WireMessage and send it over Nearby.
    private func sendSecure(_ payload: Data, feature: String, label: String) {
        sendApp(WireMessage.serialize(payload: payload, feature: feature), label: label)
    }

    private func receiveLoop() {
        fc?.receiveFrame { [weak self] data in
            guard let self else { return }
            guard let data else { self.log("connection closed"); self.teardown(); return }
            do { try self.process(data) } catch { self.log("error: \(error)") }
            self.receiveLoop()
        }
    }

    /// Release per-connection state on close so a dead channel stops the retry
    /// timer and frees reassembly buffers.
    private func teardown() {
        crosStateTimer?.invalidate(); crosStateTimer = nil
        openTimer?.invalidate(); openTimer = nil
        opened = false
        fc = nil
        pending.removeAll()
        pendingFiles.removeAll()
        state = .connecting
    }

    private func process(_ data: Data) throws {
        switch state {
        case .connecting, .sentClientInit:
            // Expect UKEY2 ServerInit (raw UKEY2 message). The phone may first send
            // its own plaintext OfflineFrame(s); skip anything that isn't ServerInit.
            if Pb.readFields(data).varint(1) == Ukey2.typeServerInit {
                let (clientFinished, derived) = try ukey.handleServerInit(data)
                fc?.sendFrame(clientFinished)
                let salt = Data(SessionKeys.salt)
                let d2dClient = Ukey2.hkdf(derived.nextSecret, salt: salt, info: Data("client".utf8), length: 32)
                let d2dServer = Ukey2.hkdf(derived.nextSecret, salt: salt, info: Data("server".utf8), length: 32)
                let ch = SecureContext(encodeKey: d2dClient, decodeKey: d2dServer)  // we are the client
                ch.lenientSequence = true
                nearby = ch
                fc?.sendFrame(NearbyFrames.connectionResponse(accept: true))
                log("← ServerInit; → ClientFinished + ConnectionResponse(accept); NC channel keyed (auth \(derived.authString.prefix(4).hex)…)")
                state = .deriving
            } else {
                let t = NearbyFrames.frameType(data)
                log("← plaintext frame type \(t.map(String.init) ?? "?") (\(data.count)B) — skipped")
            }

        case .deriving:
            // The phone's plaintext ConnectionResponse; then the channel is encrypted
            // and we (the secure_channel initiator) send D2D [Initiator Hello].
            let t = NearbyFrames.frameType(data)
            if t == NearbyFrames.frameConnectionResponse {
                log("← phone ConnectionResponse — Nearby channel up ✅")
                state = .secure
                if !helloSent {
                    helloSent = true
                    sendSecure(handshake.initiatorHello(), feature: WireMessage.authFeature, label: "[Initiator Hello]")
                }
            } else {
                log("← (deriving) frame type \(t.map(String.init) ?? "?") (\(data.count)B)")
            }

        case .secure:
            guard let n = nearby else { return }
            let plain: Data
            do { plain = try n.decode(data) } catch {
                log("← non-decryptable \(data.count)B (\(error))"); return
            }
            // payloadBody returns nil for non-PayloadTransfer frames, so try it
            // first and only parse the frame type for the other branches.
            if let (id, body, last) = NearbyFrames.payloadBody(plain) {
                pending[id, default: Data()] += body
                if (pending[id]?.count ?? 0) > maxReassembly {
                    log("payload \(id) exceeded reassembly cap — dropping")
                    pending[id] = nil; pendingFiles[id] = nil; return
                }
                guard last else { return }
                let full = pending.removeValue(forKey: id) ?? Data()
                if let photo = pendingFiles.removeValue(forKey: id) {
                    writeFullPhoto(photo, data: full)   // a camera-roll FILE payload
                } else if !full.isEmpty {
                    handleSecureChannel(full)
                }
            } else if NearbyFrames.frameType(plain) == NearbyFrames.frameKeepAlive {
                fc?.sendFrame(n.encode(NearbyFrames.keepAlive(ack: true, seq: 0)))
            } else {
                log("← 🔓 frame type \(NearbyFrames.frameType(plain).map(String.init) ?? "?") (\(plain.count)B)")
            }
        }
    }

    // MARK: secure_channel layer (layer 2) — mirrors BleRadio.handleChannelMessage

    private func handleSecureChannel(_ wire: Data) {
        guard let (message, feature) = WireMessage.parse(wire) else {
            log("← non-WireMessage payload (\(wire.count)B): \(wire.prefix(32).hex)")
            return
        }
        if ctx == nil {
            // First secure-channel message after our hello = phone's [Responder Auth].
            log("← [Responder Auth] (\(message.count)B) — deriving session, sending [Initiator Auth]")
            do {
                let auth = try handshake.initiatorAuth(forResponderAuth: message)
                ctx = handshake.context
                sendSecure(auth, feature: WireMessage.authFeature, label: "[Initiator Auth]")
                log("🔑 secure_channel established over Nearby")
                requestFeatures()
                crosStateTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] t in
                    guard let self else { t.invalidate(); return }
                    if self.gotPhoneHub { t.invalidate(); return }
                    self.requestFeatures()
                }
            } catch { log("D2D auth failed: \(error)") }
            return
        }
        do {
            let payload = try ctx!.decode(message)
            if feature == PhoneHub.feature {
                switch PhoneHub.messageType(payload) {
                case PhoneHub.fetchCameraRollItemsResponse:
                    let photos = PhoneHub.parseCameraRoll(payload)
                    for p in photos { photoByKey[p.key] = p }
                    log("📷 CAMERA ROLL: \(photos.count) recent item(s)")
                    savePhotos(photos)
                    onPhotos?(photos)
                    if downloadPhotos {
                        for p in photos { sendPhoneHub(PhoneHub.fetchCameraRollItemData(p), label: "FetchItemData \(p.fileName)") }
                    }
                case PhoneHub.fetchCameraRollItemDataResponse:
                    if let r = PhoneHub.parseCameraRollItemData(payload), r.available, let photo = photoByKey[r.key] {
                        pendingFiles[r.payloadId] = photo
                        log("   ⬇︎ \(photo.fileName): payload \(r.payloadId) available — initiating transfer")
                        sendPhoneHub(PhoneHub.initiateCameraRollTransfer(photo, payloadId: r.payloadId), label: "InitiateTransfer")
                    }
                default:
                    gotPhoneHub = true
                    crosStateTimer?.invalidate()
                    log("📱 PHONE HUB over Nearby ✅\n\(PhoneHub.describe(payload))")
                    if let snap = PhoneHub.parse(payload) {
                        onSnapshot?(snap)
                        if fetchPhotos, !sentPhotoFetch {
                            sentPhotoFetch = true
                            sendPhoneHub(PhoneHub.fetchCameraRollItems(max: 12), label: "FetchCameraRollItems")
                        }
                    }
                }
            } else if feature == Tether.feature {
                log("📡 \(Tether.parse(payload).summary)")
            } else {
                log("🔓 [\(feature)] \(payload.count)B: \(payload.prefix(64).hex)")
            }
            onMessage?(payload)
        } catch { log("decode failed [\(feature)] (\(message.count)B): \(error)") }
    }

    private func requestFeatures() {
        guard let ctx else { return }
        sendSecure(ctx.encode(PhoneHub.crosState(cameraRoll: fetchPhotos)), feature: PhoneHub.feature, label: "CrosState (phone_hub)")
    }

    /// Write each thumbnail to `photoDir` and log the item.
    private func savePhotos(_ photos: [PhoneHub.Photo]) {
        ensurePhotoDir()
        for p in photos {
            let info = "\(p.fileName.isEmpty ? p.key : p.fileName)  \(p.mime)  \(p.sizeBytes / 1024)KB"
            guard let data = p.thumbnail, !data.isEmpty else { log("   🖼  \(info) (no thumbnail)"); continue }
            let base = ((p.fileName.isEmpty ? p.key : p.fileName) as NSString).deletingPathExtension
            let safe = base.isEmpty ? "photo-\(abs(p.key.hashValue))" : base.replacingOccurrences(of: "/", with: "_")
            let path = "\(photoDir)/\(safe).thumb.\(p.thumbIsPng ? "png" : "jpg")"
            do { try writeSecure(data, to: path); log("   🖼  \(info) → \(path)") }
            catch { log("   🖼  \(info) (save failed: \(error))") }
        }
    }

    /// Write a downloaded full-resolution camera-roll file to `photoDir`.
    private func writeFullPhoto(_ p: PhoneHub.Photo, data: Data) {
        ensurePhotoDir()
        let name = p.fileName.isEmpty ? "photo-\(abs(p.key.hashValue))" : p.fileName.replacingOccurrences(of: "/", with: "_")
        let path = "\(photoDir)/\(name)"
        do { try writeSecure(data, to: path); log("   ✅ downloaded \(data.count / 1024)KB → \(path)") }
        catch { log("   full-photo save failed: \(error)") }
    }

    /// Send a Phone Hub request (e.g. PhoneHub.dismissNotification / inlineReply /
    /// ringDevice) over the authenticated channel.
    public func sendPhoneHub(_ message: Data, label: String) {
        guard let ctx else { log("sendPhoneHub: not authenticated yet"); return }
        sendSecure(ctx.encode(message), feature: PhoneHub.feature, label: label)
    }
}
#endif
