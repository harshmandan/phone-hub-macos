import Foundation
import PhoneHubKit

/// Persists AppConfig to Application Support; copies imported phones into their own
/// folders; round-trips a phone as a .zip bundle.
enum ConfigStore {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PhoneHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static var supportDir: URL { url.deletingLastPathComponent() }
    static let probeIdentityPath = "/Users/harsh/Developer/phone-hub-macos/probe/phone_identity.json"

    struct ImportError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func load() -> AppConfig {
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(AppConfig.self, from: d) { return c }
        let d = defaults(); save(d); return d   // persist so ids stay stable
    }

    static func save(_ c: AppConfig) {
        if let d = try? JSONEncoder().encodePretty(c) { try? d.write(to: url) }
    }

    /// Dev convenience: one phone pointing straight at the repo probe files.
    static func defaults() -> AppConfig {
        var c = AppConfig()
        if FileManager.default.fileExists(atPath: probeIdentityPath) {
            let idj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: probeIdentityPath)))) as? [String: Any] ?? [:]
            let p = PhoneSetup(name: (idj["name"] as? String) ?? "Pixel 9",
                               btMac: (idj["btMac"] as? String) ?? "00:00:00:00:00:00",
                               account: "you@example.com",
                               identityPath: probeIdentityPath)
            c.phones = [p]; c.activePhoneId = p.id
        }
        return c
    }

    // MARK: per-phone files

    static func phoneDir(_ id: UUID) -> URL { supportDir.appendingPathComponent("phones/\(id.uuidString)", isDirectory: true) }

    /// Copy a `phone_identity.json` + its sibling `device_keys.json` into a fresh
    /// per-phone folder; return the PhoneSetup pointing at the copies.
    static func importPhone(fromIdentity identityURL: URL, account: String = "") throws -> PhoneSetup {
        let fm = FileManager.default
        let keysSrc = identityURL.deletingLastPathComponent().appendingPathComponent("device_keys.json")
        guard fm.fileExists(atPath: keysSrc.path) else {
            throw ImportError(message: "device_keys.json not found next to \(identityURL.lastPathComponent).")
        }
        guard let idj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: identityURL))) as? [String: Any],
              idj["handshakePubKeyB64"] != nil, idj["beaconSeeds"] != nil else {
            throw ImportError(message: "\(identityURL.lastPathComponent) isn't a valid phone identity file.")
        }
        let id = UUID()
        let dir = phoneDir(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let idDest = dir.appendingPathComponent("phone_identity.json")
        let keysDest = dir.appendingPathComponent("device_keys.json")
        for (src, dst) in [(identityURL, idDest), (keysSrc, keysDest)] {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
        return PhoneSetup(id: id, name: (idj["name"] as? String) ?? "Phone",
                          btMac: (idj["btMac"] as? String) ?? "", account: account, identityPath: idDest.path)
    }

    /// Import a phone from a .zip bundle (identity + keys + account/name/mac).
    static func importBundle(from src: URL) throws -> PhoneSetup {
        let b = try ConnectionBundle.unpack(src)
        defer { try? FileManager.default.removeItem(at: b.root) }
        var p = try importPhone(fromIdentity: b.identity, account: b.meta?.account ?? "")
        if let m = b.meta {
            if !m.name.isEmpty { p.name = m.name }
            if !m.btMac.isEmpty { p.btMac = m.btMac }
        }
        return p
    }

    /// Export one phone as a .zip bundle.
    static func exportBundle(_ phone: PhoneSetup, to dest: URL) throws {
        try ConnectionBundle.export(identityPath: phone.identityPath,
            meta: .init(account: phone.account, name: phone.name, btMac: phone.btMac), to: dest)
    }

    static func removePhoneFiles(_ id: UUID) { try? FileManager.default.removeItem(at: phoneDir(id)) }

    // MARK: master token (from web sign-in)

    static var masterTokenURL: URL { supportDir.appendingPathComponent("master_token") }
    static func saveMasterToken(_ token: String) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? token.data(using: .utf8)?.write(to: masterTokenURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: masterTokenURL.path)
    }
    static var hasMasterToken: Bool { FileManager.default.fileExists(atPath: masterTokenURL.path) }
}

private extension JSONEncoder {
    func encodePretty<T: Encodable>(_ value: T) throws -> Data {
        outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encode(value)
    }
}
