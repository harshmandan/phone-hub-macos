import Foundation
import CryptoKit

/// Quick Start (the QR "quick setup with your Android phone" flow).
/// Ports the QR + the AES-256-GCM handshake from Chromium
/// chrome/browser/ash/login/oobe_quick_start/connectivity/.
///
/// The QR and handshake are the small, self-contained parts. The transport —
/// Nearby Connections (BLE + Wi-Fi + UKEY2) — is the large layer still to build,
/// and the `authString` below comes from that session.
public enum QuickStart {

    // DeviceRole (handshake_helpers.h)
    public static let roleTarget = 1   // the Chromebook (us)
    public static let roleSource = 2   // the phone

    // MARK: QR code

    public struct Bootstrap {
        public let advertisingId: Data   // 10 bytes
        public let sharedSecret: Data    // 32 bytes
    }

    public static func newBootstrap() -> Bootstrap {
        Bootstrap(advertisingId: randomData(10), sharedSecret: randomData(32))
    }

    /// The QR contents: https://signin.google/qs/<advertising_id>?key=<secret>
    /// (qr_code.cc GetQRCodeURLString).
    public static func qrURL(_ b: Bootstrap) -> String {
        let id = b.advertisingId.base64url.replacingOccurrences(of: "=", with: "")
        let key = b.sharedSecret.base64EncodedString()
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let keyEnc = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return "https://signin.google/qs/\(id)?key=\(keyEnc)"
    }

    // MARK: AES-256-GCM handshake

    /// BuildHandshakeMessage: AES-256-GCM(secret) over AuthenticationPayload
    /// {role, auth_string}, wrapped in AesGcmAuthenticationMessage.
    public static func buildHandshakeMessage(authString: String, secret: Data,
                                             role: Int, nonce: Data? = nil) throws -> Data {
        let n = nonce ?? randomData(12)
        let authPayload = Pb.varint(1, UInt64(bitPattern: Int64(role))) + Pb.bytes(2, Data(authString.utf8))

        let box = try AES.GCM.seal(authPayload, using: SymmetricKey(data: secret),
                                   nonce: AES.GCM.Nonce(data: n))
        let payload = box.ciphertext + box.tag  // crypto::aead Seal returns ct||tag

        let v1 = Pb.bytes(1, n) + Pb.bytes(2, payload)
        return Pb.varint(1, 1 /* V1 */) + Pb.message(2, v1)
    }

    /// VerifyHandshakeMessage: decrypt and check role + auth_string.
    public static func verifyHandshakeMessage(_ message: Data, secret: Data,
                                              expectedRole: Int, expectedAuthString: String) -> Bool {
        let top = Pb.readFields(message)
        guard top.varint(1) == 1, let v1Bytes = top.bytes(2) else { return false }
        let v1 = Pb.readFields(v1Bytes)
        guard let nonce = v1.bytes(1), let payload = v1.bytes(2), payload.count >= 16 else { return false }
        let ct = payload.prefix(payload.count - 16)
        let tag = payload.suffix(16)
        do {
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                               ciphertext: ct, tag: tag)
            let plain = try AES.GCM.open(sealed, using: SymmetricKey(data: secret))
            let ap = Pb.readFields(plain)
            let role = ap.varint(1).map { Int(Int64(bitPattern: $0)) }
            let authString = ap.bytes(2).map { String(decoding: $0, as: UTF8.self) }
            return role == expectedRole && authString == expectedAuthString
        } catch {
            return false
        }
    }

    static func randomData(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }
}
