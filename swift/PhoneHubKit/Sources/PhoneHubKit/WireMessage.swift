import Foundation

/// SecureChannel WireMessage framing. GMS's BleSecureChannel expects every
/// message (handshake + features) wrapped as:
///   [0x03 version][uint16 big-endian body length] + body
/// where body = JSON {"payload": base64url(inner), "feature": "<feature>"}.
/// (Confirmed live: sending a raw SecureMessage made the phone log
/// "unsupported version: 10" — it read the proto's 0x0a tag as the version.)
///
/// Source (kMessageFormatVersionThree, Serialize/Deserialize, JSON keys):
///   https://chromium.googlesource.com/chromium/src/+/a753229/components/cryptauth/wire_message.cc
/// (Later moved to chromeos/ash/services/secure_channel/wire_message.cc, identical.)
enum WireMessage {
    static let authFeature = "auth"
    static let versionThree: UInt8 = 3   // header = [3][uint16 len] (≤64KB messages)
    static let versionFour: UInt8 = 4    // header = [4][uint32 len] (large messages)

    static func serialize(payload: Data, feature: String) -> Data {
        let json = "{\"payload\":\"\(payload.base64url)\",\"feature\":\"\(feature)\"}"
        let body = Data(json.utf8)
        let n = body.count
        var out: Data
        if n <= 0xFFFF {
            out = Data([versionThree, UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        } else {
            // Version 4: 4-byte big-endian length, for bodies that overflow 16 bits
            // (base64-inflated JSON of a large message).
            out = Data([versionFour, UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff),
                        UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        }
        out += body
        return out
    }

    /// Extract the inner payload bytes and the feature from a received
    /// WireMessage. Handles version 3 ([3][uint16 len]) and version 4
    /// ([4][uint32 len]) — GMS picks version 4 for large messages (e.g. a Phone
    /// Hub status snapshot with icons, >64KB), seen over the Nearby medium.
    static func parse(_ data: Data) -> (payload: Data, feature: String)? {
        guard let first = data.first else { return nil }
        let headerLen: Int
        switch first {
        case versionThree: headerLen = 3   // 1 version + 2 length
        case versionFour:  headerLen = 5   // 1 version + 4 length
        default: return nil
        }
        guard data.count > headerLen else { return nil }
        let body = Data(data.dropFirst(headerLen))
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let b64 = obj["payload"] as? String else { return nil }
        var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let payload = Data(base64Encoded: s) else { return nil }
        return (payload, (obj["feature"] as? String) ?? "")
    }
}
