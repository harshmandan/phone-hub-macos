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
    static let updateNotificationModeRequest: UInt16 = 3
    static let ringDeviceRequest: UInt16 = 5
    static let dismissNotificationRequest: UInt16 = 9
    static let notificationInlineReplyRequest: UInt16 = 11

    static func typePrefix(_ t: UInt16) -> Data { Data([UInt8(t >> 8), UInt8(t & 0xff)]) }

    /// PROVIDE_CROS_STATE with notifications ON + should_provide_eche_status —
    /// what a real Chromebook sends on connect; the phone replies with a
    /// PHONE_STATUS_SNAPSHOT. CrosState: notification_setting(1)=NOTIFICATIONS_ON,
    /// should_provide_eche_status(5)=true. Bytes: 00 00 08 01 28 01.
    public static func crosState() -> Data {
        typePrefix(provideCrosState) + Pb.varint(1, 1) + Pb.varint(5, 1)
    }

    // MARK: outgoing requests (phonehub_api.proto message types)

    /// DISMISS_NOTIFICATION_REQUEST { notification_id = 1 }.
    public static func dismissNotification(id: Int64) -> Data {
        typePrefix(dismissNotificationRequest) + Pb.varint(1, UInt64(bitPattern: id))
    }

    /// NOTIFICATION_INLINE_REPLY_REQUEST { notification_id = 1; reply_text = 2 }.
    public static func inlineReply(id: Int64, text: String) -> Data {
        typePrefix(notificationInlineReplyRequest)
            + Pb.varint(1, UInt64(bitPattern: id)) + Pb.bytes(2, Data(text.utf8))
    }

    /// RING_DEVICE_REQUEST { ring_status = 1 } (find-my-phone). 1 = RINGING.
    public static func ringDevice(on: Bool) -> Data {
        typePrefix(ringDeviceRequest) + Pb.varint(1, on ? 1 : 0)
    }

    static func chargingName(_ v: UInt64) -> String {
        ["not_charging", "AC", "USB", "wireless"].indices.contains(Int(v))
            ? ["not_charging", "AC", "USB", "wireless"][Int(v)] : "\(v)"
    }

    // MARK: incoming notifications

    public struct Note {
        public let id: Int64
        public let app: String        // visible_name, else package_name
        public let title: String
        public let text: String
        public let canReply: Bool     // has a TEXT-input action
    }

    public struct Snapshot {
        public let isUpdate: Bool
        public let status: String     // battery / signal / carrier summary
        public let notifications: [Note]
        public let removedIds: [Int64]
    }

    /// Notification { id=1, origin_app=3(App{package_name=1, visible_name=2}),
    /// title=5, text_content=6, actions=7(Action{type=3; TEXT=1}) }.
    static func parseNote(_ data: Data) -> Note {
        let n = Pb.readFields(data)
        let app = Pb.readFields(n.bytes(3) ?? Data())
        let appName = app.string(2) ?? app.string(1) ?? ""
        let canReply = Pb.readRepeatedBytes(data, 7).contains { Pb.readFields($0).varint(3) == 1 }
        return Note(id: Int64(bitPattern: n.varint(1) ?? 0),
                    app: appName, title: n.string(5) ?? "", text: n.string(6) ?? "",
                    canReply: canReply)
    }

    /// Parse a PHONE_STATUS_SNAPSHOT / PHONE_STATUS_UPDATE into structured data.
    public static func parse(_ payload: Data) -> Snapshot? {
        guard payload.count >= 2 else { return nil }
        let type = (UInt16(payload[payload.startIndex]) << 8) | UInt16(payload[payload.startIndex + 1])
        guard type == phoneStatusSnapshot || type == phoneStatusUpdate else { return nil }
        let body = Data(payload.dropFirst(2))
        let f = Pb.readFields(body)
        let p = Pb.readFields(f.bytes(1) ?? Data())
        let batt = p.varint(1).map { "\($0)%" } ?? "?"
        let signal = p.varint(5).map { "\($0)/4" } ?? "?"
        let carrier = p.string(6) ?? ""
        let android = p.varint(13).map { " android=\($0)" } ?? ""
        let status = "battery=\(batt) charging=\(p.varint(2).map(chargingName) ?? "?") signal=\(signal) carrier=\(carrier)\(android)"
        let notes = Pb.readRepeatedBytes(body, 2).map(parseNote)
        // removed_notification_ids (field 3) is a packed repeated int64 (update only).
        var removedIds: [Int64] = []
        if type == phoneStatusUpdate, case .bytes(let packed)? = f[3] {
            var i = packed.startIndex
            while i < packed.endIndex {
                var v: UInt64 = 0, s = 0
                while i < packed.endIndex { let b = packed[i]; i = packed.index(after: i); v |= UInt64(b & 0x7F) << s; if b & 0x80 == 0 { break }; s += 7 }
                removedIds.append(Int64(bitPattern: v))
            }
        }
        return Snapshot(isUpdate: type == phoneStatusUpdate, status: status,
                        notifications: notes, removedIds: removedIds)
    }

    /// Human-readable multi-line summary of a received phone_hub payload.
    public static func describe(_ payload: Data) -> String {
        guard payload.count >= 2 else { return "empty" }
        let type = (UInt16(payload[payload.startIndex]) << 8) | UInt16(payload[payload.startIndex + 1])
        if let s = parse(payload) {
            let name = s.isUpdate ? "PHONE_STATUS_UPDATE" : "PHONE_STATUS_SNAPSHOT"
            var lines = ["\(name)  \(s.status)"]
            for n in s.notifications {
                let r = n.canReply ? " [replyable]" : ""
                let t = n.text.isEmpty ? "" : " — \(n.text.prefix(80))"
                lines.append("    🔔 [\(n.app)] \(n.title)\(t)  (id=\(n.id))\(r)")
            }
            for id in s.removedIds { lines.append("    ✕ dismissed id=\(id)") }
            return lines.joined(separator: "\n")
        }
        let body = Data(payload.dropFirst(2))
        return "phone_hub type \(type), \(body.count)B: \(body.prefix(48).hex)"
    }
}
