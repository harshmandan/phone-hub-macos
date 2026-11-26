import Foundation

/// Coarse "time ago" for the last-synced label: "just now", "15 seconds ago",
/// "1 minute ago", "2 hours ago". Buckets by 5s under a minute so it doesn't
/// flicker every second.
func relativeTime(since date: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    switch s {
    case ..<5:   return "just now"
    case ..<60:  let v = (s / 5) * 5; return "\(v) second\(v == 1 ? "" : "s") ago"
    case ..<3600:
        let m = s / 60; return "\(m) minute\(m == 1 ? "" : "s") ago"
    case ..<86400:
        let h = s / 3600; return "\(h) hour\(h == 1 ? "" : "s") ago"
    default:
        let d = s / 86400; return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}

/// UI-facing phone state, decoupled from PhoneHubKit's wire types so the views
/// never touch protocol internals.
struct PhoneState: Equatable {
    var phoneName = "Phone"
    var battery: Int? = nil
    var charging = false
    var signalBars: Int? = nil        // 0…4
    var carrier = ""
    var cameraRollGranted = false
    var androidVersion: Int? = nil
    var lastUpdated: Date? = nil
}

struct UINotification: Identifiable, Equatable {
    let id: Int64
    var app: String
    var title: String
    var text: String
    var canReply: Bool
}

struct UIPhoto: Identifiable, Equatable {
    var id: String { key }
    let key: String
    var fileName: String
    var mime: String
    var sizeKB: Int
    var thumbnailPath: String?        // decoded thumbnail saved on disk
    var localPath: String?            // full-resolution file, once downloaded
    var downloading = false
    var isVideo: Bool { mime.hasPrefix("video/") }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case arming                       // bringing up the BLE channel that arms the phone
    case connecting                   // opening the Nearby Connections channel
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .arming: return "Connecting…"
        case .connecting: return "Opening channel…"
        case .connected: return "Connected"
        case .error(let m): return "Error: \(m)"
        }
    }

    var isBusy: Bool { self == .arming || self == .connecting }
}

/// Instant Tethering (phone hotspot) state for the UI.
enum HotspotStatus: Equatable {
    case off                      // phone hasn't offered tethering
    case available                // phone offers a hotspot; user can turn it on
    case turningOn                // asked the phone, waiting for credentials
    case joining(String)          // joining the Wi-Fi network (SSID)
    case joined(String)           // Mac is on the phone's hotspot (SSID)
    case failed(String)

    var label: String {
        switch self {
        case .off: return "Hotspot"
        case .available: return "Turn on hotspot"
        case .turningOn: return "Turning on…"
        case .joining(let s): return "Joining \(s)…"
        case .joined(let s): return "On hotspot \(s)"
        case .failed(let m): return "Hotspot failed: \(m)"
        }
    }
}

/// One set-up phone (identity + keys live in its own folder; the account is the
/// Google account it's linked to). We never store a password — only a token.
struct PhoneSetup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Phone"
    var btMac = ""
    var account = ""
    var identityPath = ""             // this phone's phone_identity.json
}

/// Persisted app configuration. One phone is "active" (connected) at a time;
/// the list is ready for multiple later.
struct AppConfig: Codable, Equatable {
    var phones: [PhoneSetup] = []
    var activePhoneId: UUID?
    var startAtLogin = false

    /// The phone we connect to (the chosen one, else the first).
    var activePhone: PhoneSetup? { phones.first { $0.id == activePhoneId } ?? phones.first }

    // Read-only convenience for the single-active-phone engine/panel.
    var phoneBtMac: String { activePhone?.btMac ?? "" }
    var identityPath: String { activePhone?.identityPath ?? "" }
    var phoneName: String { activePhone?.name ?? "Phone" }
    var account: String { activePhone?.account ?? "" }
}
