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
    static let fetchCameraRollItemsRequest: UInt16 = 15
    static let fetchCameraRollItemsResponse: UInt16 = 16
    static let fetchCameraRollItemDataRequest: UInt16 = 17
    static let fetchCameraRollItemDataResponse: UInt16 = 18
    static let initiateCameraRollItemTransferRequest: UInt16 = 19
    static let featureSetupRequest: UInt16 = 24

    static func typePrefix(_ t: UInt16) -> Data { Data([UInt8(t >> 8), UInt8(t & 0xff)]) }

    /// The 2-byte MessageType prefix of a received phone_hub payload.
    public static func messageType(_ payload: Data) -> UInt16 {
        guard payload.count >= 2 else { return 0xffff }
        return (UInt16(payload[payload.startIndex]) << 8) | UInt16(payload[payload.startIndex + 1])
    }

    /// PROVIDE_CROS_STATE: notification_setting(1)=NOTIFICATIONS_ON, optional
    /// camera_roll_setting(2)=CAMERA_ROLL_ON, should_provide_eche_status(5)=true —
    /// what a real Chromebook sends on connect; the phone replies with a
    /// PHONE_STATUS_SNAPSHOT.
    public static func crosState(cameraRoll: Bool = false) -> Data {
        var s = Pb.varint(1, 1)
        if cameraRoll { s += Pb.varint(2, 1) }
        s += Pb.varint(5, 1)
        return typePrefix(provideCrosState) + s
    }

    /// FETCH_CAMERA_ROLL_ITEMS_REQUEST { max_item_count = 1 } — ask the phone for
    /// its most recent photos/videos (metadata + thumbnails inline).
    public static func fetchCameraRollItems(max: Int = 12) -> Data {
        typePrefix(fetchCameraRollItemsRequest) + Pb.varint(1, UInt64(max))
    }

    /// FEATURE_SETUP_REQUEST { notification_setup_requested=1, camera_roll_setup
    /// _requested=2 } — asks the phone to prompt the user to grant the feature
    /// (needs a tap on the phone). Required before camera-roll access is granted.
    public static func featureSetup(notifications: Bool = false, cameraRoll: Bool = false) -> Data {
        var s = Data()
        if notifications { s += Pb.varint(1, 1) }
        if cameraRoll { s += Pb.varint(2, 1) }
        return typePrefix(featureSetupRequest) + s
    }

    private static func metadataProto(_ p: Photo) -> Data {
        // CameraRollItemMetadata { key=1, mime_type=2, last_modified=3, size=4, file_name=5 }
        var m = Data()
        m += Pb.bytes(1, Data(p.key.utf8))
        m += Pb.bytes(2, Data(p.mime.utf8))
        m += Pb.varint(3, UInt64(bitPattern: p.lastModifiedMs))
        m += Pb.varint(4, UInt64(bitPattern: p.sizeBytes))
        m += Pb.bytes(5, Data(p.fileName.utf8))
        return m
    }

    /// FETCH_CAMERA_ROLL_ITEM_DATA_REQUEST { metadata=1 } — ask whether a full item
    /// is available and get a Nearby payload id to receive it on.
    public static func fetchCameraRollItemData(_ p: Photo) -> Data {
        typePrefix(fetchCameraRollItemDataRequest) + Pb.message(1, metadataProto(p))
    }

    /// INITIATE_CAMERA_ROLL_ITEM_TRANSFER_REQUEST { metadata=1, payload_id=2 } —
    /// tell the phone to start sending the file on `payloadId`.
    public static func initiateCameraRollTransfer(_ p: Photo, payloadId: Int64) -> Data {
        typePrefix(initiateCameraRollItemTransferRequest)
            + Pb.message(1, metadataProto(p)) + Pb.varint(2, UInt64(bitPattern: payloadId))
    }

    /// Parse FETCH_CAMERA_ROLL_ITEM_DATA_RESPONSE { file_availability=1, payload_id
    /// =2, metadata=3 }. Returns (available, payloadId, key) or nil.
    public static func parseCameraRollItemData(_ payload: Data) -> (available: Bool, payloadId: Int64, key: String)? {
        guard messageType(payload) == fetchCameraRollItemDataResponse else { return nil }
        let f = Pb.readFields(Data(payload.dropFirst(2)))
        let key = Pb.readFields(f.bytes(3) ?? Data()).string(1) ?? ""
        return (f.varint(1) == 1, Int64(bitPattern: f.varint(2) ?? 0), key)
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
        let cam = " cameraRoll=\(cameraRollAccessName(p.varint(15)))"
        let status = "battery=\(batt) charging=\(p.varint(2).map(chargingName) ?? "?") signal=\(signal) carrier=\(carrier)\(android)\(cam)"
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

    // MARK: incoming camera roll

    public struct Photo {
        public let key: String        // stable id (use to request the full file)
        public let fileName: String
        public let mime: String
        public let sizeBytes: Int64
        public let lastModifiedMs: Int64
        public let thumbnail: Data?   // encoded JPEG/PNG bytes (inline)
        public let thumbIsPng: Bool
    }

    /// Parse FETCH_CAMERA_ROLL_ITEMS_RESPONSE { items = 1 (repeated CameraRollItem
    /// { metadata = 1, thumbnail = 2 }) }.
    public static func parseCameraRoll(_ payload: Data) -> [Photo] {
        guard messageType(payload) == fetchCameraRollItemsResponse else { return [] }
        let body = Data(payload.dropFirst(2))
        return Pb.readRepeatedBytes(body, 1).map { itemBytes in
            let item = Pb.readFields(itemBytes)
            let m = Pb.readFields(item.bytes(1) ?? Data())
            let th = Pb.readFields(item.bytes(2) ?? Data())
            return Photo(key: m.string(1) ?? "", fileName: m.string(5) ?? "",
                         mime: m.string(2) ?? "",
                         sizeBytes: Int64(bitPattern: m.varint(4) ?? 0),
                         lastModifiedMs: Int64(bitPattern: m.varint(3) ?? 0),
                         thumbnail: th.bytes(2), thumbIsPng: th.varint(1) == 2)
        }
    }

    static func cameraRollAccessName(_ v: UInt64?) -> String {
        switch v { case 1: return "granted"; case 0, nil: return "not-granted"; default: return "\(v!)" }
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
