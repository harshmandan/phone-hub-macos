import Foundation

/// A portable connection bundle: a .zip holding `phone_identity.json`,
/// `device_keys.json`, and `meta.json` (account / phone name / BT MAC). Both the
/// CLI (`export` command) and the app produce it, and the app imports it — so a
/// user moves a working setup with one file instead of juggling the raw JSONs.
public enum ConnectionBundle {
    public struct Meta: Codable {
        public var account: String
        public var name: String
        public var btMac: String
        public init(account: String = "", name: String = "", btMac: String = "") {
            self.account = account; self.name = name; self.btMac = btMac
        }
    }

    public struct BundleError: Error, LocalizedError { let message: String; public var errorDescription: String? { message } }

    /// Zip the identity + keys (siblings) plus meta.json into `dest`.
    public static func export(identityPath: String, meta: Meta, to dest: URL) throws {
        let fm = FileManager.default
        let idURL = URL(fileURLWithPath: identityPath)
        let keysURL = idURL.deletingLastPathComponent().appendingPathComponent("device_keys.json")
        guard fm.fileExists(atPath: idURL.path) else { throw BundleError(message: "phone_identity.json not found at \(identityPath)") }
        guard fm.fileExists(atPath: keysURL.path) else { throw BundleError(message: "device_keys.json not found next to phone_identity.json") }

        let stage = fm.temporaryDirectory.appendingPathComponent("phonehub-bundle-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: idURL, to: stage.appendingPathComponent("phone_identity.json"))
        try fm.copyItem(at: keysURL, to: stage.appendingPathComponent("device_keys.json"))
        try JSONEncoder().encode(meta).write(to: stage.appendingPathComponent("meta.json"))

        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        // --norsrc/--noextattr keep the zip clean (no __MACOSX resource forks).
        try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", stage.path, dest.path])
    }

    /// Unzip `src` to a temp dir and locate the parts (wherever they sit in the zip).
    /// Caller copies identity/keys where it wants, then should delete `root`.
    public static func unpack(_ src: URL) throws -> (root: URL, identity: URL, keys: URL, meta: Meta?) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("phonehub-unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", src.path, root.path])
        let id = try find("phone_identity.json", under: root)
        let keys = try find("device_keys.json", under: root)
        var meta: Meta?
        if let m = try? find("meta.json", under: root) { meta = try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: m)) }
        return (root, id, keys, meta)
    }

    private static func find(_ name: String, under dir: URL) throws -> URL {
        if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.lastPathComponent == name { return u }
        }
        throw BundleError(message: "\(name) not found in the bundle — is this a PhoneHub export?")
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BundleError(message: "archive tool failed: \(e)")
        }
    }
}
