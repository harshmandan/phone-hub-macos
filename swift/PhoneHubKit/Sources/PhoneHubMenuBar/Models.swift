import Foundation

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
        case .arming: return "Waking phone…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error(let m): return "Error: \(m)"
        }
    }

    var isBusy: Bool { self == .arming || self == .connecting }
}

/// Persisted app configuration (also what config export/import round-trips).
struct AppConfig: Codable, Equatable {
    var phoneBtMac: String = ""
    var phoneName: String = "Phone"
    var account: String = ""
    var identityPath: String = ""     // phone_identity.json
    var autoConnect: Bool = false
    var showNotifications: Bool = true
    var esp32Port: String = ""
    var esp32Fqbn: String = "esp32:esp32:XIAO_ESP32C6"
}
