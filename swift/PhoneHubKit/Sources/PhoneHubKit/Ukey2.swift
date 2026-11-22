import Foundation
import CryptoKit

/// UKEY2 authenticated key exchange — the security core of Nearby Connections.
/// Ports google/ukey2 (ukey.proto + ukey2_handshake.cc). Produces the shared
/// "next-protocol secret" and the "auth string" (the auth_string our Quick Start
/// handshake consumes).
///
/// P256_SHA512 cipher: NIST P-256 ECDH, SHA-512 commitments, SHA-256 KDF base.
public enum Ukey2 {
    // Ukey2Message.Type
    static let typeClientInit: UInt64 = 2
    static let typeServerInit: UInt64 = 3
    static let typeClientFinish: UInt64 = 4
    // Ukey2HandshakeCipher
    static let cipherP256Sha512: UInt64 = 100
    static let nextProtocol = "AES_256_CBC-HMAC_SHA256"

    static let saltNext = Data("UKEY2 v1 next".utf8)
    static let saltAuth = Data("UKEY2 v1 auth".utf8)

    static func rand(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    static func wrap(type: UInt64, data: Data) -> Data {
        Pb.varint(1, type) + Pb.bytes(2, data)
    }

    static func hkdf(_ ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        CryptoKit.HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt, info: info, outputByteCount: length)
            .withUnsafeBytes { Data($0) }
    }

    public struct Derived: Equatable {
        public let nextSecret: Data
        public let authString: Data
    }

    /// Derive the shared outputs from one side's private key + the peer's public
    /// key and the two wrapped init messages.
    static func derive(ownPrivate: P256.KeyAgreement.PrivateKey,
                       peerPublic: P256.KeyAgreement.PublicKey,
                       wrappedClientInit: Data, wrappedServerInit: Data,
                       authLength: Int = 32) throws -> Derived {
        let derivedSecretKey = try SecureMessage.masterKey(ownPrivate, peerPublic)  // SHA256(ECDH)
        let info = wrappedClientInit + wrappedServerInit
        return Derived(
            nextSecret: hkdf(derivedSecretKey, salt: saltNext, info: info, length: 32),
            authString: hkdf(derivedSecretKey, salt: saltAuth, info: info, length: authLength))
    }

    /// Run the full three-message handshake in-process (for tests / as the
    /// reference). Returns both sides' derived outputs — they must match.
    public static func selfHandshake(authLength: Int = 32) throws -> (client: Derived, server: Derived) {
        // Client finished (committed to first).
        let clientKey = P256.KeyAgreement.PrivateKey()
        let clientFinished = Pb.bytes(1, SecureMessage.genericPublicKey(clientKey.publicKey))
        let wrappedClientFinished = wrap(type: typeClientFinish, data: clientFinished)
        let commitment = Data(SHA512.hash(data: wrappedClientFinished))

        // Client init (carries the commitment).
        var clientInit = Data()
        clientInit += Pb.varint(1, 1)               // version
        clientInit += Pb.bytes(2, rand(32))         // random
        let cipherCommitment = Pb.varint(1, cipherP256Sha512) + Pb.bytes(2, commitment)
        clientInit += Pb.message(3, cipherCommitment)  // cipher_commitments[0]
        clientInit += Pb.bytes(4, Data(nextProtocol.utf8))
        let wrappedClientInit = wrap(type: typeClientInit, data: clientInit)

        // Server init.
        let serverKey = P256.KeyAgreement.PrivateKey()
        var serverInit = Data()
        serverInit += Pb.varint(1, 1)               // version
        serverInit += Pb.bytes(2, rand(32))         // random
        serverInit += Pb.varint(3, cipherP256Sha512)
        serverInit += Pb.bytes(4, SecureMessage.genericPublicKey(serverKey.publicKey))
        let wrappedServerInit = wrap(type: typeServerInit, data: serverInit)

        // Server verifies the commitment against the client-finished it receives.
        guard Data(SHA512.hash(data: wrappedClientFinished)) == commitment else {
            throw SecureMessage.SecureMessageError(message: "commitment mismatch")
        }

        // Both derive.
        let client = try derive(ownPrivate: clientKey, peerPublic: serverKey.publicKey,
                                wrappedClientInit: wrappedClientInit, wrappedServerInit: wrappedServerInit,
                                authLength: authLength)
        let server = try derive(ownPrivate: serverKey, peerPublic: clientKey.publicKey,
                                wrappedClientInit: wrappedClientInit, wrappedServerInit: wrappedServerInit,
                                authLength: authLength)
        return (client, server)
    }
}
