import Foundation

/// Phone Hub application messages, carried on the SecureChannel under WireMessage
/// feature "phone_hub". Framing (message_sender_impl.cc `SerializeMessage`):
/// a 2-byte big-endian MessageType followed by the serialized phonehub_api.proto
/// message.
///
/// Sources (Chromium chromeos/ash/components/phonehub, branch main):
///   proto/phonehub_api.proto (MessageType, CrosState, PhoneStatusSnapshot):
///     https://chromium.googlesource.com/chromium/src/+/main/chromeos/ash/components/phonehub/proto/phonehub_api.proto
///   CrosState send (the connect trigger):
///     https://chromium.googlesource.com/chromium/src/+/main/chromeos/ash/components/phonehub/cros_state_sender.cc
///     https://chromium.googlesource.com/chromium/src/+/main/chromeos/ash/components/phonehub/message_sender_impl.cc
///   feature string "phone_hub":
///     https://chromium.googlesource.com/chromium/src/+/main/chromeos/ash/components/phonehub/phone_hub_manager_impl.cc
public enum PhoneHub {
    public static let feature = "phone_hub"

    // proto::MessageType (phonehub_api.proto)
    static let provideCrosState: UInt16 = 0
    static let phoneStatusSnapshot: UInt16 = 1
    static let phoneStatusUpdate: UInt16 = 2

    static func typePrefix(_ t: UInt16) -> Data { Data([UInt8(t >> 8), UInt8(t & 0xff)]) }

    /// PROVIDE_CROS_STATE with notifications ON + should_provide_eche_status —
    /// what a real Chromebook sends on connect; the phone replies with a
    /// PHONE_STATUS_SNAPSHOT. CrosState: notification_setting(1)=NOTIFICATIONS_ON,
    /// should_provide_eche_status(5)=true. Bytes: 00 00 08 01 28 01.
    public static func crosState() -> Data {
        typePrefix(provideCrosState) + Pb.varint(1, 1) + Pb.varint(5, 1)
    }

    static func chargingName(_ v: UInt64) -> String {
        ["not_charging", "AC", "USB", "wireless"].indices.contains(Int(v))
            ? ["not_charging", "AC", "USB", "wireless"][Int(v)] : "\(v)"
    }

    /// Human-readable summary of a received phone_hub payload (2-byte type + proto).
    public static func describe(_ payload: Data) -> String {
        guard payload.count >= 2 else { return "empty" }
        let type = (UInt16(payload[payload.startIndex]) << 8) | UInt16(payload[payload.startIndex + 1])
        let body = Data(payload.dropFirst(2))
        switch type {
        case phoneStatusSnapshot, phoneStatusUpdate:
            let name = type == phoneStatusSnapshot ? "PHONE_STATUS_SNAPSHOT" : "PHONE_STATUS_UPDATE"
            let f = Pb.readFields(body)
            guard let propsBytes = f.bytes(1) else { return "\(name) (no properties)" }
            let p = Pb.readFields(propsBytes)
            let batt = p.varint(1).map { "\($0)%" } ?? "?"
            let charging = p.varint(2).map(chargingName) ?? "?"
            let signal = p.varint(5).map { "\($0)/4" } ?? "?"
            let carrier = p.bytes(6).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let android = p.varint(13).map { " android=\($0)" } ?? ""
            return "\(name)  battery=\(batt) charging=\(charging) signal=\(signal) carrier=\(carrier)\(android)"
        default:
            return "phone_hub type \(type), \(body.count)B: \(body.prefix(48).hex)"
        }
    }
}
