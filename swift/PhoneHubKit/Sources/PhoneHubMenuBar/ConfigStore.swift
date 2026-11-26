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

    /// The app's support directory (where we copy an imported setup).
    static var supportDir: URL { url.deletingLastPathComponent() }

    /// Where the Google master token from web sign-in is kept (owner-only).
    static var masterTokenURL: URL { supportDir.appendingPathComponent("master_token") }

    /// Persist the master token 0600 (never logged, never shown).
    static func saveMasterToken(_ token: String) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? token.data(using: .utf8)?.write(to: masterTokenURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: masterTokenURL.path)
    }

    static var hasMasterToken: Bool { FileManager.default.fileExists(atPath: masterTokenURL.path) }

    /// The default CLI/probe identity path, if the repo is present.
    static let probeIdentityPath = "/Users/harsh/Developer/phone-hub-macos/probe/phone_identity.json"

    struct ImportError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Import an existing CLI/probe connection: copy `phone_identity.json` and its
    /// sibling `device_keys.json` into our support dir and return a config pointing
    /// at the copies (so the app no longer depends on the repo path). The phone's
    /// BT MAC and name are read from the identity file.
    static func importSetup(from identityURL: URL) throws -> AppConfig {
        let fm = FileManager.default
        let keysSrc = identityURL.deletingLastPathComponent().appendingPathComponent("device_keys.json")
        guard fm.fileExists(atPath: keysSrc.path) else {
            throw ImportError(message: "device_keys.json not found next to \(identityURL.lastPathComponent). Pick the probe's phone_identity.json — its keys file must sit beside it.")
        }
        guard let idj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: identityURL))) as? [String: Any],
              idj["handshakePubKeyB64"] != nil, idj["beaconSeeds"] != nil else {
            throw ImportError(message: "\(identityURL.lastPathComponent) isn't a valid phone identity file.")
        }
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let idDest = supportDir.appendingPathComponent("phone_identity.json")
        let keysDest = supportDir.appendingPathComponent("device_keys.json")
        for (src, dst) in [(identityURL, idDest), (keysSrc, keysDest)] {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
        var c = load()
        c.identityPath = idDest.path
        c.phoneBtMac = (idj["btMac"] as? String) ?? c.phoneBtMac
        c.phoneName = (idj["name"] as? String) ?? c.phoneName
        save(c)
        return c
    }
}

private extension JSONEncoder {
    func encodePretty<T: Encodable>(_ value: T) throws -> Data {
        outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encode(value)
    }
}
