import Foundation

/// Loads the phone's identity (beacon seeds, long-term public key) and our device
/// key from the probe's JSON files — `phone_identity.json` plus the sibling
/// `device_keys.json`. Centralizes the parsing that the selftest commands used to
/// each repeat inline.
public struct PhoneIdentity {
    public let seeds: [Eid.BeaconSeed]
    public let name: String
    public let phonePublicGeneric: Data   // phone's long-term public key (generic-public-key bytes)
    public let ourPrivatePem: String      // our DeviceSync:BetterTogether private key PEM

    public struct LoadError: Error { public let message: String }

    private static func parseSeeds(_ idj: [String: Any]) -> [Eid.BeaconSeed] {
        guard let arr = idj["beaconSeeds"] as? [[String: Any]] else { return [] }
        return arr.compactMap { s in
            guard let hex = s["dataHex"] as? String,
                  let start = (s["startMs"] as? NSNumber)?.int64Value,
                  let end = (s["endMs"] as? NSNumber)?.int64Value else { return nil }
            return Eid.BeaconSeed(data: Data(hex: hex), startTimeMs: start, endTimeMs: end)
        }
    }

    private static func json(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Full load: seeds + phone public key + our private key (for a live connection).
    public static func load(_ identityPath: String) throws -> PhoneIdentity {
        guard let idj = json(identityPath) else { throw LoadError(message: "cannot read \(identityPath)") }
        guard let phonePubB64 = idj["handshakePubKeyB64"] as? String,
              let phonePub = Data(base64Encoded: phonePubB64) else {
            throw LoadError(message: "no handshakePubKeyB64 in \(identityPath)")
        }
        let keysPath = (identityPath as NSString).deletingLastPathComponent + "/device_keys.json"
        guard let kj = json(keysPath),
              let keys = kj["keys"] as? [String: Any],
              let bt = keys["DeviceSync:BetterTogether"] as? [String: Any],
              let pem = bt["privatePem"] as? String else {
            throw LoadError(message: "cannot load our device key from \(keysPath)")
        }
        return PhoneIdentity(seeds: parseSeeds(idj), name: (idj["name"] as? String) ?? "phone",
                             phonePublicGeneric: phonePub, ourPrivatePem: pem)
    }

    /// Seeds + name only (for scanning; no keys required).
    public static func loadSeeds(_ identityPath: String) -> (seeds: [Eid.BeaconSeed], name: String) {
        guard let idj = json(identityPath) else { return ([], "phone") }
        return (parseSeeds(idj), (idj["name"] as? String) ?? "phone")
    }
}
