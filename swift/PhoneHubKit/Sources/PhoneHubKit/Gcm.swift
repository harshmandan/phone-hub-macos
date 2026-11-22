import Foundation

/// GCM InstanceID token for CryptAuth, the way GMS does it: an Android check-in
/// then a GMS register3. Port of `get_gcm_token.py`.
enum Gcm {
    static let checkinURL = URL(string: "https://android.clients.google.com/checkin")!
    static let registerURL = URL(string: "https://android.clients.google.com/c2dm/register3")!
    static let authorizedEntity = "16502139086"
    static let gmsPackage = "com.google.android.gms"
    static let gmsCert = "58e1c4133f7441ec3d2c270270a14802da47ba0e"
    static let gmsVersionCode = "244433022"
    static let buildFingerprint = "google/sailfish/sailfish:8.1.0/OPM1.171019.011/4448085:user/release-keys"
    static let buildSdk: UInt64 = 27

    struct GcmError: Error { let message: String }

    static func generateInstanceId() -> String {
        var raw = Data(count: 8)
        raw.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        raw[0] = UInt8((112 + (Int(raw[0]) & 0x0F)) & 0xFF)
        return raw.base64url.replacingOccurrences(of: "=", with: "")
    }

    private static func checkinRequest() -> Data {
        var build = Data()
        build += Pb.bytes(1, Data(buildFingerprint.utf8))   // fingerprint
        build += Pb.varint(10, buildSdk)                     // sdkVersion
        var checkin = Data()
        checkin += Pb.message(1, build)                      // build
        checkin += Pb.varint(2, 0)                           // lastCheckinMs
        var req = Data()
        req += Pb.varint(2, 0)                               // androidId = 0
        req += Pb.message(4, checkin)                        // checkin
        req += Pb.bytes(6, Data("en_US".utf8))               // locale
        req += Pb.varint(14, 3)                              // version
        req += Pb.varint(20, 0)                              // fragment (required)
        return req
    }

    /// Returns (androidId, securityToken).
    static func checkin() async throws -> (UInt64, UInt64) {
        var request = URLRequest(url: checkinURL)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = checkinRequest()
        let (data, _) = try await URLSession.shared.data(for: request)
        let fields = Pb.readFields(data)
        guard let androidId = fields.varint(7), let securityToken = fields.varint(8) else {
            throw GcmError(message: "check-in response missing androidId/securityToken")
        }
        return (androidId, securityToken)
    }

    static func register(androidId: UInt64, securityToken: UInt64, instanceId: String) async throws -> String {
        let params = [
            "app": gmsPackage, "cert": gmsCert, "app_ver": gmsVersionCode, "gmsv": gmsVersionCode,
            "device": String(androidId), "sender": authorizedEntity,
            "subtype": authorizedEntity, "X-subtype": authorizedEntity,
            "subscription": authorizedEntity, "X-subscription": authorizedEntity,
            "appid": instanceId, "scope": "GCM", "X-scope": "GCM",
            "osv": "27", "cliv": "iid-202414000",
        ]
        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.setValue("AidLogin \(androidId):\(securityToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Form.encode(params)

        for _ in 0..<5 {  // PHONE_REGISTRATION_ERROR is often transient
            let (data, _) = try await URLSession.shared.data(for: request)
            let text = String(decoding: data, as: UTF8.self)
            if let range = text.range(of: "token=") {
                return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw GcmError(message: "GCM register failed")
    }

    /// Returns (instanceId, gcmToken).
    static func token() async throws -> (String, String) {
        let (androidId, securityToken) = try await checkin()
        let instanceId = generateInstanceId()
        let gcmToken = try await register(androidId: androidId, securityToken: securityToken, instanceId: instanceId)
        return (instanceId, gcmToken)
    }
}
