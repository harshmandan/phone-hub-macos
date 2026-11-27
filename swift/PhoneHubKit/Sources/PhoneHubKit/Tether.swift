import Foundation

/// Instant Tethering (Magic Tether) messages, carried on the SecureChannel under
/// WireMessage feature "magic_tether". Unlike Phone Hub, tether wraps each
/// message as JSON {"type": <int>, "data": base64url(serialized proto, with
/// padding)} (message_wrapper.cc) — NOT a 2-byte-type prefix. Attestation-free,
/// same trust tier as EasyUnlock.
///
/// Sources (Chromium chromeos/ash/components/tether, branch main):
///   feature "magic_tether": .../secure_channel_host_connection.cc
///   JSON "type"/"data" framing: .../message_wrapper.cc
///   proto (MessageType, TetherAvailability*/ConnectTethering*): .../proto/tether.proto
///   send/receive flow: .../tether_availability_operation.cc, .../connect_tethering_operation.cc
public enum Tether {
    public static let feature = "magic_tether"

    // proto MessageType (tether.proto)
    static let availabilityRequest = 1
    static let availabilityResponse = 2
    static let connectRequest = 3
    static let connectResponse = 4
    static let disconnectRequest = 5
    static let keepAliveTickle = 6
    static let keepAliveResponse = 7

    /// Wrap an (optional) serialized proto as {"type":N,"data":"<base64url>"}.
    /// All request bodies are empty protos, so `data` is "".
    static func wrap(type: Int, proto: Data = Data()) -> Data {
        let data = proto.isEmpty ? "" : proto.base64url   // base64url WITH padding
        return Data("{\"type\":\(type),\"data\":\"\(data)\"}".utf8)
    }

    public static func availabilityRequest_() -> Data { wrap(type: availabilityRequest) }
    public static func connectRequest_() -> Data { wrap(type: connectRequest) }
    public static func keepAlive() -> Data { wrap(type: keepAliveTickle) }

    private static func b64urlDecode(_ s: String) -> Data {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t) ?? Data()
    }

    private static func deviceStatus(_ ds: Data) -> String {
        let d = Pb.readFields(ds)
        let batt = d.varint(1).map { "\($0)%" } ?? "?"
        let carrier = d.bytes(2).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let bars = d.varint(3).map { "\($0)/4" } ?? "?"
        return "battery=\(batt) carrier=\(carrier) signal=\(bars)"
    }

    public struct Parsed {
        public let type: Int
        public let summary: String
        public let available: Bool           // availability response: TETHER_AVAILABLE / SETUP_NEEDED
        public let ssid: String?             // connect response
        public let password: String?
    }

    /// Parse a received magic_tether message into a structured result + summary.
    public static func parse(_ payload: Data) -> Parsed {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? Int else {
            return Parsed(type: -1, summary: "tether non-JSON \(payload.count)B", available: false, ssid: nil, password: nil)
        }
        let f = Pb.readFields(b64urlDecode((obj["data"] as? String) ?? ""))
        switch type {
        case availabilityResponse:
            let codes = ["UNKNOWN_ERROR", "TETHER_AVAILABLE", "SETUP_NEEDED", "NO_RECEPTION",
                         "NO_SIM_CARD", "NOTIFICATIONS_DISABLED", "NOTIFICATIONS_DISABLED", "LAST_PROVISIONING_FAILED"]
            let rc = Int(f.varint(1) ?? 0)
            let name = rc < codes.count ? codes[rc] : "\(rc)"
            let status = f.bytes(2).map { " — " + deviceStatus($0) } ?? ""
            return Parsed(type: type, summary: "TETHER_AVAILABILITY_RESPONSE: \(name)\(status)",
                          available: rc == 1 || rc == 2, ssid: nil, password: nil)
        case connectResponse:
            let rc = Int(f.varint(1) ?? 0)
            let ssid = f.bytes(2).flatMap { String(data: $0, encoding: .utf8) }
            let pw = f.bytes(3).flatMap { String(data: $0, encoding: .utf8) }
            let codes = ["UNKNOWN_ERROR", "SUCCESS", "PROVISIONING_FAILED", "TETHERING_TIMEOUT",
                         "TETHERING_UNSUPPORTED", "NO_CELL_DATA", "ENABLING_HOTSPOT_FAILED", "ENABLING_HOTSPOT_TIMEOUT"]
            let name = rc < codes.count ? codes[rc] : "\(rc)"
            return Parsed(type: type, summary: "CONNECT_TETHERING_RESPONSE: \(name) SSID=\(ssid ?? "-") password=\(pw ?? "-")",
                          available: false, ssid: ssid, password: pw)
        case keepAliveResponse:
            return Parsed(type: type, summary: "KEEP_ALIVE_TICKLE_RESPONSE" + (f.bytes(1).map { " — " + deviceStatus($0) } ?? ""),
                          available: false, ssid: nil, password: nil)
        default:
            return Parsed(type: type, summary: "magic_tether type \(type)", available: false, ssid: nil, password: nil)
        }
    }
}
