import Foundation
import CryptoKit

/// CryptAuth v2 enrollment: register the Mac as a CHROME device and enroll its
/// key bundles. Port of `metadata.py` + `enroll_keys.py` + `probe_enroll.py`.
public enum Enrollment {
    static let apiKey = "AIzaSyAP-gfH3qvi6vgHZbSYwQ_XHqV_mXHhzIk"
    static let androidCert = "58E1C4133F7441EC3D2C270270A14802DA47BA0E"
    static let base = "https://cryptauthenrollment.googleapis.com/"
    static let keyProofSalt = Data("CryptAuth Key Proof".utf8)

    struct EnrollError: Error { let message: String }

    static func post(_ urlString: String, token: String, body: [String: Any]) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("com.google.android.gms", forHTTPHeaderField: "x-android-package")
        req.setValue(androidCert, forHTTPHeaderField: "x-android-cert")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// One EnrollSingleKeyRequest. Generates a P256 key, proves possession.
    static func keyRequest(sessionIdB64: String, keyName: String, fixedHandle: Data?) -> [String: String] {
        let sessionBytes = Data(base64Encoded: sessionIdB64) ?? Data()
        let priv = P256.Signing.PrivateKey()
        let keyMaterial = SecureMessage.genericPublicKey(rawXY: priv.publicKey.rawRepresentation)
        let handle: Data
        if let fixed = fixedHandle {
            handle = fixed
        } else {
            // base64url(SHA256(keyMaterial)) with padding, as bytes
            handle = Data(Data(SHA256.hash(data: keyMaterial)).base64url.utf8)
        }
        let sig = try! priv.signature(for: keyProofSalt + sessionBytes).derRepresentation
        return [
            "keyName": keyName,
            "newKeyHandle": handle.base64EncodedString(),
            "keyMaterial": keyMaterial.base64EncodedString(),
            "keyProof": sig.base64EncodedString(),
        ]
    }

    /// Debug: the base64url ClientAppMetadata for fixed inputs, to diff vs Python.
    public static func metadataB64(instanceId: String, gcmToken: String, longDeviceId: String) -> String {
        ClientAppMetadata.build(instanceId: instanceId, gcmToken: gcmToken, longDeviceId: longDeviceId)
    }

    /// Debug: fetch the token (prefix) and print the syncKeys JSON, no POST.
    public static func diag(email: String, masterToken: String) async throws -> String {
        let token = try await GoogleAuth.cryptAuthToken(email: email, masterToken: masterToken)
        let cam = ClientAppMetadata.build(instanceId: "AAAAAAAAAAA", gcmToken: "tok123",
                                          longDeviceId: "11111111-1111-1111-1111-111111111111")
        let syncBody: [String: Any] = [
            "applicationName": "com.google.android.gms",
            "clientVersion": "1.0.0",
            "syncSingleKeyRequests": [
                ["keyName": "PublicKey", "keyHandles": ["ZGV2aWNlX2tleQo="]],
                ["keyName": "DeviceSync:BetterTogether"],
            ],
            "clientMetadata": ["invocationReason": "NEW_ACCOUNT"],
            "clientAppMetadata": cam,
        ]
        let json = try JSONSerialization.data(withJSONObject: syncBody, options: [.sortedKeys])
        return "token: \(token.prefix(12))…\n" + String(decoding: json, as: UTF8.self)
    }

    public static func enroll(email: String, masterToken: String) async throws -> String {
        let token = try await GoogleAuth.cryptAuthToken(email: email, masterToken: masterToken)
        let (instanceId, gcmToken) = try await Gcm.token()  // real GCM registration
        let longDeviceId = UUID().uuidString.lowercased()
        let clientAppMetadata = ClientAppMetadata.build(
            instanceId: instanceId, gcmToken: gcmToken, longDeviceId: longDeviceId)

        let syncBody: [String: Any] = [
            "applicationName": "com.google.android.gms",
            "clientVersion": "1.0.0",
            "syncSingleKeyRequests": [
                ["keyName": "PublicKey", "keyHandles": ["ZGV2aWNlX2tleQo="]],
                ["keyName": "DeviceSync:BetterTogether"],
            ],
            "clientMetadata": ["invocationReason": "NEW_ACCOUNT"],
            "clientAppMetadata": clientAppMetadata,
        ]
        let (syncCode, syncData) = try await post(base + "v1:syncKeys", token: token, body: syncBody)
        guard syncCode == 200,
              let json = try? JSONSerialization.jsonObject(with: syncData) as? [String: Any],
              let session = json["randomSessionId"] as? String else {
            throw EnrollError(message: "syncKeys \(syncCode): \(String(decoding: syncData, as: UTF8.self))")
        }

        let enrollBody: [String: Any] = [
            "randomSessionId": session,
            "enrollSingleKeyRequests": [
                keyRequest(sessionIdB64: session, keyName: "PublicKey", fixedHandle: Data("device_key".utf8)),
                keyRequest(sessionIdB64: session, keyName: "DeviceSync:BetterTogether", fixedHandle: nil),
            ],
        ]
        let (enrollCode, enrollData) = try await post(base + "v1:enrollKeys", token: token, body: enrollBody)
        return "syncKeys 200, enrollKeys \(enrollCode): \(String(decoding: enrollData, as: UTF8.self))"
    }
}
