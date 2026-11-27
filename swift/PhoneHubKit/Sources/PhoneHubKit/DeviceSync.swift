import Foundation
import CryptoKit

/// DeviceSync: join the account's Better Together device group and read it back.
/// API: cryptauthdevicesync.googleapis.com (v1:syncMetadata, batchSetFeatureStatuses).
/// Reference (ChromeOS client + proto):
///   https://chromium.googlesource.com/chromium/src/+/main/chromeos/ash/services/device_sync/cryptauth_device_syncer_impl.cc
///   https://chromium.googlesource.com/chromium/src/+/main/chromeos/ash/services/device_sync/proto/cryptauth_better_together_device_metadata.proto
/// Port of `group_metadata.py` + `device_sync.py`. Reuses the Swift
/// SecureMessage for the ECIES group-metadata encryption.
public enum DeviceSync {
    static let host = "https://cryptauthdevicesync.googleapis.com"
    static let syncMetadataPath = "/v1:syncMetadata"
    static let betterTogetherGroup = "DeviceSync:BetterTogether"

    static func randomBtAddress() -> String {
        var b = Data(count: 6)
        b.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 6, $0.baseAddress!) }
        return b.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// BetterTogetherDeviceMetadata: public_key(1), no_pii_device_name(2),
    /// bluetooth_public_address(4).
    static func deviceMetadata(betterTogetherKeyMaterial: Data) -> Data {
        var m = Data()
        m += Pb.bytes(1, betterTogetherKeyMaterial)
        m += Pb.bytes(2, Data("Chromebook".utf8))
        m += Pb.bytes(4, Data(randomBtAddress().utf8))
        return m
    }

    /// syncMetadata, returns a human-readable summary of the group.
    public static func syncMetadata(enrolled: Enrollment.Enrolled) async throws -> String {
        // We create the group key, so we hold the private key.
        let groupKey = P256.KeyAgreement.PrivateKey()
        let groupPub = groupKey.publicKey
        let metadata = deviceMetadata(betterTogetherKeyMaterial: enrolled.betterTogetherKeyMaterial)
        let encrypted = try SecureMessage.encrypt(payload: metadata, to: groupPub)

        let body: [String: Any] = [
            "context": [
                "group": betterTogetherGroup,
                "clientMetadata": ["invocationReason": "INITIALIZATION"],
                "deviceId": enrolled.instanceId,
                "deviceIdToken": enrolled.gcmToken,
            ],
            "groupPublicKey": SecureMessage.genericPublicKey(groupPub).base64EncodedString(),
            "encryptedMetadata": encrypted.base64EncodedString(),
            "needGroupPrivateKey": false,
        ]

        let (code, data) = try await Enrollment.post(host + syncMetadataPath, token: enrolled.token, body: body)
        if code != 200 {
            return "syncMetadata \(code): \(String(decoding: data, as: UTF8.self))"
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let packets = (json?["encryptedMetadata"] as? [[String: Any]]) ?? []
        var lines = ["syncMetadata 200 — \(packets.count) device(s) in the group:"]
        for p in packets {
            let id = p["deviceId"] as? String ?? "?"
            let name = p["deviceName"] as? String ?? "?"
            lines.append("  - id=\(id)  name=\(name)")
        }
        return lines.joined(separator: "\n")
    }

    /// Enroll then immediately sync — a full server-side round-trip.
    public static func enrollAndSync(email: String, masterToken: String) async throws -> String {
        let enrolled = try await Enrollment.enrollReturningIdentity(email: email, masterToken: masterToken)
        let summary = try await syncMetadata(enrolled: enrolled)
        return "enrolled \(enrolled.instanceId)\n" + summary
    }
}
