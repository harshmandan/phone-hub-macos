import Foundation

/// Persists AppConfig to Application Support, and round-trips it for export/import.
enum ConfigStore {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PhoneHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> AppConfig {
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(AppConfig.self, from: d) {
            return c
        }
        return defaults()
    }

    static func save(_ c: AppConfig) {
        if let d = try? JSONEncoder().encodePretty(c) { try? d.write(to: url) }
    }

    /// Dev convenience: prefill from the repo's probe files if present.
    static func defaults() -> AppConfig {
        var c = AppConfig()
        let probe = "/Users/harsh/Developer/phone-hub-macos/probe/phone_identity.json"
        if FileManager.default.fileExists(atPath: probe) {
            c.identityPath = probe
            c.phoneBtMac = "00:00:00:00:00:00"
            c.phoneName = "Pixel 9"
        }
        return c
    }

    static func export(_ c: AppConfig, to dest: URL) throws { try JSONEncoder().encodePretty(c).write(to: dest) }
    static func load(from src: URL) throws -> AppConfig { try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: src)) }
}

private extension JSONEncoder {
    func encodePretty<T: Encodable>(_ value: T) throws -> Data {
        outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encode(value)
    }
}
