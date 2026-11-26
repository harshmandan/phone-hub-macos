import Foundation

/// SecureChannel WireMessage framing. GMS's BleSecureChannel expects every
/// message (handshake + features) wrapped as:
///   [0x03 version][uint16 big-endian body length] + body
/// where body = JSON {"payload": base64url(inner), "feature": "<feature>"}.
/// (Confirmed live: sending a raw SecureMessage made the phone log
/// "unsupported version: 10" — it read the proto's 0x0a tag as the version.)
enum WireMessage {
    static let authFeature = "auth"
    static let versionThree: UInt8 = 3

    static func serialize(payload: Data, feature: String) -> Data {
        let json = "{\"payload\":\"\(payload.base64url)\",\"feature\":\"\(feature)\"}"
        let body = Data(json.utf8)
        var out = Data([versionThree, UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff)])
        out += body
        return out
    }

    /// Extract the inner payload bytes from a received WireMessage (ignores the
    /// feature for now). Returns nil if the framing isn't version 3.
    static func payload(_ data: Data) -> Data? {
        guard data.count > 3, data[data.startIndex] == versionThree else { return nil }
        let body = Data(data.dropFirst(3))
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let b64 = obj["payload"] as? String else { return nil }
        var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
