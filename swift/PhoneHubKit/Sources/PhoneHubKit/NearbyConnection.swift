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
        fc.sendFrame(ch.encode(NearbyFrames.payloadBytes(id: pid, body: body)))
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
            // phone's ConnectionResponse (plaintext). Reply with ours (accept),
            // then the channel is encrypted.
            log("got phone ConnectionResponse (\(data.count)B); sending accept")
            fc.sendFrame(NearbyFrames.connectionResponse(accept: true))
            state = .secure
            if let secret = quickStartSecret, let auth = authString {
                // Quick Start app layer — Target drives: handshake → bootstrapOptions.
                // bootstrapOptions makes the phone surface its account picker.
                do {
                    let hs = try QuickStart.buildHandshakeMessage(authBytes: auth, secret: secret,
                                                                  role: QuickStart.roleTarget)
                    sendApp(hs, label: "handshake")
                    sendApp(QuickStartMessages.bootstrapOptions(), label: "bootstrapOptions")
                } catch { log("handshake build failed: \(error)") }
            } else if let ch = channel {
                fc.sendFrame(ch.encode(NearbyFrames.keepAlive(ack: false, seq: 1)))
                log("sent ConnectionResponse(accept) + an encrypted keep-alive")
            }

        case .secure:
            // encrypted frames — decrypt with the channel. Dump the phone's
            // app-layer messages (JSON in PayloadTransferFrame BYTES) so a live
            // run captures exactly what the Quick Start source sends.
            guard let ch = channel else { return }
            let plain = try ch.decode(data)
            let t = NearbyFrames.frameType(plain)
            if t == NearbyFrames.framePayloadTransfer, let (id, body, last) = NearbyFrames.payloadBody(plain) {
                let txt = String(data: body, encoding: .utf8) ?? "<non-utf8>"
                log("🔓 app payload id=\(id) \(body.count)B last=\(last)")
                log("    utf8: \(txt.prefix(500))")
                log("    hex : \(Data(body.prefix(96)).hex)")
                if let cfg = QuickStartMessages.parseBootstrapConfigurations(body) {
                    let email = cfg["email"] as? String
                    let iid = (cfg["instanceId"] ?? cfg["instance_id"]) as? String
                    if email != nil || iid != nil {
                        log("    🎯 bootstrapConfigurations — email=\(email ?? "?") instanceId=\(iid ?? "?")")
                    }
                }
            } else {
                log("🔓 decrypted frame (\(plain.count)B) type \(t.map(String.init) ?? "?")")
            }
        }
    }
}
