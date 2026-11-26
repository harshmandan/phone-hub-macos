import Foundation
import CryptoKit

/// The Better Together SecureChannel "DeviceToDevice" (D2D) authentication
/// handshake, run over the uWeave channel after it connects. Port of Chromium
/// components/cryptauth/device_to_device_* (copies in the scratchpad).
///
/// Keys: PSK = SHA256(ECDH(our long-term device key, phone long-term key)) — a
/// pre-shared key both sides already have. A fresh ephemeral P256 keypair per
/// attempt yields the session key = SHA256(ECDH(ephemerals)), HKDF-split into
/// directional encode keys. We are the INITIATOR.
public enum D2D {
    static let gcmTypeResponderHello: UInt64 = 12
    static let gcmTypeMessage: UInt64 = 13
    static let filler = Data([0xae])            // kPayloadFiller
    static let protocolVersion: UInt64 = 1

    /// salt = SHA256("D2D"); directional keys = HKDF-SHA256(session, salt, purpose).
    static let salt = Data(SHA256.hash(data: Data("D2D".utf8)))
    static func directionalKeys(_ session: Data) -> (initiator: Data, responder: Data) {
        (Ukey2.hkdf(session, salt: salt, info: Data("initiator".utf8), length: 32),
         Ukey2.hkdf(session, salt: salt, info: Data("responder".utf8), length: 32))
    }

    static func gcmMetadata(_ type: UInt64) -> Data { Pb.varint(1, type) + Pb.varint(2, 1) }
    static func deviceToDeviceMessage(_ message: Data, seq: UInt64) -> Data {
        Pb.bytes(1, message) + Pb.varint(2, seq)
    }

    public final class Handshake {
        private let psk: Data
        private let ephemeral = P256.KeyAgreement.PrivateKey()
        public private(set) var context: SecureContext?

        public init(ourLongTermPrivate: P256.KeyAgreement.PrivateKey,
                    phoneLongTermPublic: P256.KeyAgreement.PublicKey) throws {
            psk = try SecureMessage.masterKey(ourLongTermPrivate, phoneLongTermPublic)
        }

        /// [Initiator Hello]: SecureMessage, encryption NONE, HMAC-signed with the
        /// PSK; public_metadata = InitiatorHello{ our ephemeral pubkey, version }.
        public func initiatorHello() -> Data {
            let initiatorHello = Pb.bytes(1, SecureMessage.genericPublicKey(ephemeral.publicKey))
                + Pb.varint(2, protocolVersion)
            return SecureMessage.create(key: psk, payload: filler,
                                        publicMetadata: initiatorHello, encrypt: false)
        }

        /// Given the phone's [Responder Auth], derive the session keys and return
        /// the [Initiator Auth] to send. Sets `context` for post-auth messages.
        public func initiatorAuth(forResponderAuth responderAuth: Data) throws -> Data {
            // The phone's ephemeral public key is in the outer header's
            // decryption_key_id (field 4) = ResponderHello{ public_dh_key, version }.
            guard let rhBytes = SecureMessage.headerField(responderAuth, 4) else {
                throw SecureMessage.SecureMessageError(message: "ResponderAuth missing decryption_key_id")
            }
            let phoneEph = try SecureMessage.parseGenericPublicKey(Pb.readFields(rhBytes).bytes(1) ?? Data())
            let session = try SecureMessage.masterKey(ephemeral, phoneEph)
            let keys = directionalKeys(session)
            context = SecureContext(encodeKey: keys.initiator, decodeKey: keys.responder)

            // [Initiator Auth]: inner (AES+HMAC with PSK, body filler, the whole
            // ResponderAuth as associated data) wrapped in DeviceToDeviceMessage,
            // outer AES+HMAC with the initiator session key.
            let inner = SecureMessage.create(key: psk, payload: filler, encrypt: true,
                                             associatedData: responderAuth)
            let ddm = deviceToDeviceMessage(inner, seq: 1)
            return SecureMessage.create(key: keys.initiator, payload: ddm,
                                        publicMetadata: gcmMetadata(gcmTypeMessage), encrypt: true)
        }
    }

    /// Post-auth encrypted channel. Each message is a SecureMessage (AES+HMAC)
    /// whose body is DeviceToDeviceMessage{ message, sequence_number }; counters
    /// start at 1 (the handshake), so the first feature message is sequence 2.
    public final class SecureContext {
        private let encodeKey: Data
        private let decodeKey: Data
        private var encodeSeq: UInt64 = 1
        private var decodeSeq: UInt64 = 1

        init(encodeKey: Data, decodeKey: Data) {
            self.encodeKey = encodeKey
            self.decodeKey = decodeKey
        }

        public func encode(_ message: Data) -> Data {
            encodeSeq += 1
            let ddm = deviceToDeviceMessage(message, seq: encodeSeq)
            return SecureMessage.create(key: encodeKey, payload: ddm,
                                        publicMetadata: gcmMetadata(gcmTypeMessage), encrypt: true)
        }

        /// Decrypt an incoming SecureMessage to the inner feature payload.
        public func decode(_ secureMessage: Data) throws -> Data {
            let (payload, _) = try SecureMessage.unwrap(key: decodeKey, secureMessage: secureMessage)
            decodeSeq += 1
            return Pb.readFields(payload).bytes(1) ?? Data()   // DeviceToDeviceMessage.message
        }
    }
}
