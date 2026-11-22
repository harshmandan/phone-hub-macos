import Foundation
import CryptoKit

/// Per-direction channel keys from the handshake root key.
/// Port of `ble/session_keys.py`.
struct SessionKeys {
    static let salt = Data([
        0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83, 0x46, 0xCA, 0x1C,
        0xEE, 0x8D, 0x39, 0x09, 0xB9, 0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D,
        0x4A, 0xB3, 0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10,
    ])

    let initiator: Data
    let responder: Data

    init(rootSymmetricKey: Data) {
        initiator = Self.hkdf(rootSymmetricKey, info: Data("initiator".utf8))
        responder = Self.hkdf(rootSymmetricKey, info: Data("responder".utf8))
    }

    static func hkdf(_ ikm: Data, info: Data) -> Data {
        let key = CryptoKit.HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt, info: info, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}
