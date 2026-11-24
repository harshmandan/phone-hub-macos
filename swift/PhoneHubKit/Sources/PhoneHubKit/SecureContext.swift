import Foundation

/// The device-to-device encrypted channel after authentication.
/// Port of `ble/secure_context.py`.
final class SecureContext {
    static let gcmMetadataVersion: UInt64 = 1
    static let typeDeviceToDeviceMessage: UInt64 = 13  // securegcm.Type
    static let authSequenceNumber: UInt64 = 1

    private let encodeKey: Data
    private let decodeKey: Data
    private var encodeSeq: UInt64
    private var decodeSeq: UInt64

    enum Role { case initiator, responder }

    /// If true, decode() accepts out-of-order sequence numbers (logs instead of
    /// throwing) — useful while bringing up a live connection.
    var lenientSequence = false

    init(sessionKeys: SessionKeys, role: Role) {
        switch role {
        case .initiator:
            encodeKey = sessionKeys.initiator
            decodeKey = sessionKeys.responder
        case .responder:
            encodeKey = sessionKeys.responder
            decodeKey = sessionKeys.initiator
        }
        encodeSeq = Self.authSequenceNumber
        decodeSeq = Self.authSequenceNumber
    }

    /// Explicit per-direction keys (Nearby Connections: d2dServerKey / d2dClientKey).
    /// Nearby's D2D context starts both counters at 0, so the first message is
    /// seq 1 (a live phone rejects seq 2 with "Incorrect sequence number").
    init(encodeKey: Data, decodeKey: Data) {
        self.encodeKey = encodeKey
        self.decodeKey = decodeKey
        encodeSeq = 0
        decodeSeq = 0
    }

    func encode(_ message: Data) -> Data {
        encodeSeq += 1
        let d2d = Pb.bytes(1, message) + Pb.varint(2, encodeSeq)
        let gcm = Pb.varint(1, Self.typeDeviceToDeviceMessage) + Pb.varint(2, Self.gcmMetadataVersion)
        return SecureMessage.create(key: encodeKey, payload: d2d, publicMetadata: gcm)
    }

    struct SequenceError: Error { let expected: UInt64; let got: UInt64? }

    func decode(_ blob: Data) throws -> Data {
        let (payload, _) = try SecureMessage.unwrap(key: decodeKey, secureMessage: blob)
        let fields = Pb.readFields(payload)
        decodeSeq += 1
        let seq = fields.varint(2)
        if seq != decodeSeq {
            if lenientSequence {
                decodeSeq = seq ?? decodeSeq  // resync
            } else {
                throw SequenceError(expected: decodeSeq, got: seq)
            }
        }
        return fields.bytes(1) ?? Data()
    }
}
