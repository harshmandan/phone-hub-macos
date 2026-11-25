import Foundation
import CryptoKit

/// The Nearby Connections inbound state machine (our role: we advertise, the
/// phone connects). Drives: ConnectionRequest → UKEY2 (ClientInit/ServerInit/
/// ClientFinished) → ConnectionResponse → encrypted D2D channel → frames.
///
/// Reuses the tested pieces: Ukey2.Server, SecureContext (keyed with the Nearby
/// d2dServer/d2dClient keys), NearbyFrames. Ported from NearDrop's
/// InboundNearbyConnection. Logs every step so a live run shows how far it gets.
public final class NearbyConnection {
    enum State { case initial, gotConnectionRequest, sentServerInit, gotClientFinished, secure }

    private let fc: any FrameChannel
    private let ukey = Ukey2.Server()
    private var state: State = .initial
    private var channel: SecureContext?

    /// When set (Quick Start via QR), drive the app layer after the channel is up.
    private let quickStartSecret: Data?
    private var authString: Data?
    private var payloadId: Int64 = 1

    public init(_ fc: any FrameChannel, quickStartSecret: Data? = nil) {
        self.fc = fc
        self.quickStartSecret = quickStartSecret
    }

    public func start() {
        fc.start()
        receiveLoop()
    }

    private func log(_ s: String) { print("  [nearby] \(s)") }

    /// Send a Quick Start app-layer message as an encrypted Nearby BYTES payload.
    private func sendApp(_ body: Data, label: String) {
        guard let ch = channel else { return }
        let pid = payloadId; payloadId += 1
        // Standard Nearby BYTES payload: one data chunk, then an empty last chunk.
        fc.sendFrame(ch.encode(NearbyFrames.payloadBytes(id: pid, body: body, lastChunk: false)))
        fc.sendFrame(ch.encode(NearbyFrames.payloadBytes(id: pid, body: Data(), lastChunk: true,
                                                          totalSize: body.count, offset: body.count)))
        log("→ \(label) (\(body.count)B) as payload \(pid)")
    }

    private func receiveLoop() {
        fc.receiveFrame { [weak self] data in
            guard let self, let data else { self?.log("connection closed"); return }
            do { try self.process(data) } catch { self.log("error: \(error)") }
            self.receiveLoop()
        }
    }

    private func process(_ data: Data) throws {
        switch state {
        case .initial:
            // plaintext OfflineFrame — expect ConnectionRequest (type 1)
            let t = NearbyFrames.frameType(data)
            log("frame \(data.count)B, type \(t.map(String.init) ?? "?") (expect ConnectionRequest)")
            state = .gotConnectionRequest

        case .gotConnectionRequest:
            // raw UKEY2 ClientInit → send ServerInit
            let serverInit = try ukey.serverInit(clientInitRaw: data)
            fc.sendFrame(serverInit)
            log("UKEY2: got ClientInit (\(data.count)B), sent ServerInit (\(serverInit.count)B)")
            state = .sentServerInit

        case .sentServerInit:
            // raw UKEY2 ClientFinished → derive the channel
            let derived = try ukey.finish(clientFinishedRaw: data)
            let salt = Data(SessionKeys.salt)
            let d2dClient = Ukey2.hkdf(derived.nextSecret, salt: salt, info: Data("client".utf8), length: 32)
            let d2dServer = Ukey2.hkdf(derived.nextSecret, salt: salt, info: Data("server".utf8), length: 32)
            let ch = SecureContext(encodeKey: d2dServer, decodeKey: d2dClient)  // we are the server
            ch.lenientSequence = true
            channel = ch
            authString = derived.authString
            log("UKEY2 complete ✅ — D2D channel derived (auth \(derived.authString.prefix(4).hex)…)")
            state = .gotClientFinished

        case .gotClientFinished:
            // phone's ConnectionResponse (plaintext, type 2). Over Bluetooth the
            // phone also sends plaintext keep-alives (type 5) here — skip them.
            let t = NearbyFrames.frameType(data)
            guard t == 2 else {
                log("plaintext frame type \(t.map(String.init) ?? "?") (\(data.count)B) before ConnectionResponse — ignored")
                return
            }
            log("got phone ConnectionResponse (\(data.count)B): \(data.hex); sending accept")
            fc.sendFrame(NearbyFrames.connectionResponse(accept: true))
            state = .secure
            if let secret = quickStartSecret, let auth = authString {
                // Quick Start app layer (Chromium connection.cc): handshake now;
                // bootstrapOptions only after the phone reports user verification.
                do {
                    // Chromium passes NC's human-readable token, not the raw bytes:
                    // uppercase(websafe-base64(raw UKEY2 token)[:5]) (encryption_runner.cc).
                    let token = String(auth.base64url.prefix(5)).uppercased()
                    log("auth token for handshake: \(token)")
                    let hs = try QuickStart.buildHandshakeMessage(authString: token, secret: secret,
                                                                  role: QuickStart.roleTarget)
                    sendApp(hs, label: "handshake")
                } catch { log("handshake build failed: \(error)") }
            } else if let ch = channel {
                fc.sendFrame(ch.encode(NearbyFrames.keepAlive(ack: false, seq: 1)))
                log("sent ConnectionResponse(accept) + an encrypted keep-alive")
            }

        case .secure:
            guard let ch = channel else { return }
            let plain: Data
            do { plain = try ch.decode(data) } catch {
                let t = NearbyFrames.frameType(data)
                log("non-encrypted frame (\(data.count)B) type \(t.map(String.init) ?? "?") in secure state: \(data.prefix(48).hex) — ignored (\(error))")
                return
            }
            let t = NearbyFrames.frameType(plain)
            if t == NearbyFrames.framePayloadTransfer, let (id, body, last) = NearbyFrames.payloadBody(plain) {
                pending[id, default: Data()] += body
                guard last else { return }
                let full = pending.removeValue(forKey: id) ?? Data()
                if !full.isEmpty { handleApp(full) }
            } else if t == 5 {
                fc.sendFrame(ch.encode(NearbyFrames.keepAlive(ack: true, seq: 0)))
            } else {
                log("🔓 frame type \(t.map(String.init) ?? "?") (\(plain.count)B)")
            }
        }
    }

    // MARK: Quick Start target flow

    private var pending: [Int64: Data] = [:]
    private var sentBootstrapOptions = false
    private enum Fido { case none, sentGetInfo, sentAssertion }
    private var fido = Fido.none
    private var clientDataJSON = ""

    private func handleApp(_ body: Data) {
        let txt = String(data: body, encoding: .utf8) ?? "<\(body.count)B non-utf8 \(body.prefix(48).hex)>"
        log("⬅︎ raw \(body.count)B: \(txt.prefix(1200))")
        // Chromium's reader checks bootstrapConfigurations before quickStartPayload;
        // the phone's account reply can carry both keys.
        if let o = try? JSONSerialization.jsonObject(with: QuickStartMessages.sanitized(body)) as? [String: Any],
           o["bootstrapConfigurations"] != nil {
            let cfg = QuickStartMessages.parseBootstrapConfigurations(body) ?? [:]
            log("⬅︎ 🎯 bootstrapConfigurations \(cfg)")
            if fido == .none {
                fido = .sentGetInfo
                sendApp(QuickStartMessages.getInfoRequest(), label: "FIDO GetInfo")
            }
            return
        }
        if let inner = QuickStartMessages.quickStartPayload(body) {
            log("⬅︎ quickStartPayload \(inner)")
            if inner["user_verification_result"] != nil, !sentBootstrapOptions {
                sentBootstrapOptions = true
                sendApp(QuickStartMessages.bootstrapOptions(), label: "bootstrapOptions (account request)")
            }
            return
        }
        guard let o = try? JSONSerialization.jsonObject(with: QuickStartMessages.sanitized(body)) as? [String: Any] else {
            log("⬅︎ \(txt.prefix(200))")
            return
        }
        if let sd = o["secondDeviceAuthPayload"] {
            log("⬅︎ secondDeviceAuthPayload \(String(describing: sd).prefix(600))")
            if let d = sd as? [String: Any], let fm = d["fidoMessage"] as? String,
               let ctap = Data(base64Encoded: fm) {
                log("    CTAP response \(ctap.count)B status=0x\(String(format: "%02x", ctap.first ?? 0xff)) \(ctap.prefix(160).hex)")
            }
            if fido == .sentGetInfo {
                fido = .sentAssertion
                var ch = Data(count: 32)
                ch.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
                let challenge = ch.base64url.replacingOccurrences(of: "=", with: "")
                clientDataJSON = QuickStartMessages.clientDataJSON(challengeB64url: challenge)
                log("    clientData \(clientDataJSON)")
                let hash = Data(SHA256.hash(data: Data(clientDataJSON.utf8)))
                sendApp(QuickStartMessages.assertionRequest(clientDataHash: hash), label: "FIDO GetAssertion")
            } else if fido == .sentAssertion {
                log("    🎯 FIDO assertion received")
                // Google sign-in needs a TPM attestation cert we can't make; the Mac
                // already has the account via its master token. Tell the phone
                // setup finished (Chromium NotifyPhoneSetupComplete).
                sendApp(QuickStartMessages.bootstrapComplete(), label: "bootstrapState=2 (setup complete)")
            }
            return
        }
        if o["bootstrapConfigurations"] != nil || o["email"] != nil || o["instanceId"] != nil {
            let cfg = QuickStartMessages.parseBootstrapConfigurations(body) ?? [:]
            log("⬅︎ 🎯 bootstrapConfigurations \(cfg)")
            if fido == .none {
                fido = .sentGetInfo
                sendApp(QuickStartMessages.getInfoRequest(), label: "FIDO GetInfo")
            }
            return
        }
        log("⬅︎ \(txt.prefix(400))")
    }
}
