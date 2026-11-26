import Foundation
import CryptoKit
import CommonCrypto

/// Google securemessage: AES-256-CBC + HMAC-SHA256, master key from ECDH→SHA256.
/// Swift port of the probe's `securemessage.py`, verified against it.
enum SecureMessage {
    static let sigHmacSha256: UInt64 = 1
    static let encNone: UInt64 = 1
    static let encAes256Cbc: UInt64 = 2
    static let publicKeyTypeEcP256: UInt64 = 1

    /// CryptoOps::kSalt = SHA256("SecureMessage")
    static let salt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))

    // MARK: GenericPublicKey

    static func javaBigInt(_ coord: Data) -> Data {
        var bytes = Array(coord)
        var start = 0
        while start < bytes.count - 1 && bytes[start] == 0 { start += 1 }
        bytes = Array(bytes[start...])
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }  // keep positive
        return Data(bytes)
    }

    static func genericPublicKey(_ pub: P256.KeyAgreement.PublicKey) -> Data {
        genericPublicKey(rawXY: pub.rawRepresentation)
    }

    /// Build a GenericPublicKey from a raw 64-byte x||y (works for signing or
    /// key-agreement public keys, which share the representation).
    static func genericPublicKey(rawXY raw: Data) -> Data {
        let x = javaBigInt(raw.prefix(32))
        let y = javaBigInt(raw.suffix(32))
        let ecP256 = Pb.bytes(1, x) + Pb.bytes(2, y)
        return Pb.varint(1, publicKeyTypeEcP256) + Pb.message(2, ecP256)
    }

    private static func pad32(_ d: Data) -> Data {
        var b = Array(d)
        if b.count == 33 && b[0] == 0 { b.removeFirst() }
        while b.count < 32 { b.insert(0, at: 0) }
        return Data(b.suffix(32))
    }

    static func parseGenericPublicKey(_ data: Data) throws -> P256.KeyAgreement.PublicKey {
        let g = Pb.readFields(data)
        let ec = Pb.readFields(g.bytes(2) ?? Data())
        let x = pad32(ec.bytes(1) ?? Data())
        let y = pad32(ec.bytes(2) ?? Data())
        return try P256.KeyAgreement.PublicKey(rawRepresentation: x + y)
    }

    // MARK: key derivation

    static func hkdf(_ key: Data, _ info: Data) -> Data {
        let derived = CryptoKit.HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: salt, info: info, outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    static func masterKey(_ priv: P256.KeyAgreement.PrivateKey,
                          _ peer: P256.KeyAgreement.PublicKey) throws -> Data {
        let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
        let x = shared.withUnsafeBytes { Data($0) }  // X coordinate
        return Data(SHA256.hash(data: x))
    }

    // MARK: AES-256-CBC (CommonCrypto; CryptoKit has no CBC)

    private static func aesCbc(encrypt: Bool, key: Data, iv: Data, data: Data) -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCount = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                d.baseAddress, data.count,
                                o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        precondition(status == kCCSuccess, "AES-CBC failed")
        out.removeSubrange(moved..<out.count)
        return out
    }

    // MARK: create / unwrap (symmetric)

    static func create(key: Data, payload: Data,
                       publicMetadata: Data = Data(),
                       decryptionKeyId: Data = Data(),
                       encrypt: Bool = true,
                       associatedData: Data = Data()) -> Data {
        let sigKey = hkdf(key, Data("SIG:1".utf8))

        var header = Pb.varint(1, sigHmacSha256) + Pb.varint(2, encrypt ? encAes256Cbc : encNone)
        if !decryptionKeyId.isEmpty { header += Pb.bytes(4, decryptionKeyId) }
        var body: Data
        if encrypt {
            let encKey = hkdf(key, Data("ENC:2".utf8))
            var iv = Data(count: 16)
            iv.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            body = aesCbc(encrypt: true, key: encKey, iv: iv, data: payload)
            header += Pb.bytes(5, iv)          // iv = field 5 (before metadata, as the phone sends)
        } else {
            body = payload                      // NONE: body is the plaintext
        }
        if !publicMetadata.isEmpty { header += Pb.bytes(6, publicMetadata) }
        if !associatedData.isEmpty { header += Pb.varint(7, UInt64(associatedData.count)) }

        let headerAndBody = Pb.bytes(1, header) + Pb.bytes(2, body)
        // The signature covers headerAndBody || associated_data (associated_data
        // itself is NOT transmitted — only its length, in header field 7).
        let sig = Data(HMAC<SHA256>.authenticationCode(for: headerAndBody + associatedData,
                                                       using: SymmetricKey(data: sigKey)))
        return Pb.bytes(1, headerAndBody) + Pb.bytes(2, sig)
    }

    /// Read a header field (e.g. 4 = decryption_key_id) from a serialized
    /// SecureMessage without verifying or decrypting it.
    static func headerField(_ secureMessage: Data, _ field: Int) -> Data? {
        let sm = Pb.readFields(secureMessage)
        let hab = Pb.readFields(sm.bytes(1) ?? Data())
        return Pb.readFields(hab.bytes(1) ?? Data()).bytes(field)
    }

    struct SecureMessageError: Error { let message: String }

    static func unwrap(key: Data, secureMessage: Data) throws -> (payload: Data, publicMetadata: Data) {
        let sm = Pb.readFields(secureMessage)
        guard let headerAndBody = sm.bytes(1), let signature = sm.bytes(2) else {
            throw SecureMessageError(message: "malformed SecureMessage")
        }
        let sigKey = hkdf(key, Data("SIG:1".utf8))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: headerAndBody, using: SymmetricKey(data: sigKey)))
        guard expected == signature else { throw SecureMessageError(message: "bad signature") }

        let hab = Pb.readFields(headerAndBody)
        let header = Pb.readFields(hab.bytes(1) ?? Data())
        let body = hab.bytes(2) ?? Data()
        let encKey = hkdf(key, Data("ENC:2".utf8))
        let iv = header.bytes(5) ?? Data()
        let payload = aesCbc(encrypt: false, key: encKey, iv: iv, data: body)
        return (payload, header.bytes(6) ?? Data())
    }

    // MARK: ECIES (encrypt to a public key)

    static func encrypt(payload: Data, to groupPub: P256.KeyAgreement.PublicKey) throws -> Data {
        let session = P256.KeyAgreement.PrivateKey()
        let master = try masterKey(session, groupPub)
        return create(key: master, payload: payload,
                      decryptionKeyId: genericPublicKey(session.publicKey))
    }

    static func decrypt(secureMessage: Data, with groupPriv: P256.KeyAgreement.PrivateKey) throws -> Data {
        let sm = Pb.readFields(secureMessage)
        let hab = Pb.readFields(sm.bytes(1) ?? Data())
        let header = Pb.readFields(hab.bytes(1) ?? Data())
        let sessionPub = try parseGenericPublicKey(header.bytes(4) ?? Data())
        let master = try masterKey(groupPriv, sessionPub)
        return try unwrap(key: master, secureMessage: secureMessage).payload
    }
}
