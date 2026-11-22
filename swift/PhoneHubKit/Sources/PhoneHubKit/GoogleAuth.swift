import Foundation

/// Exchange a durable master token for a scoped access token (the gpsoauth
/// perform_oauth step). Port of `probe_auth.py`.
enum GoogleAuth {
    /// The device id the master token is bound to (must match the one used when
    /// the master token was minted).
    static let androidId = "3812d1b8e3a0c4f9"
    static let gmsPackage = "com.google.android.gms"
    static let gmsSig = "38918a453d07199354f8b19af05ec6562ced5788"
    static let cryptauthScope = "oauth2:https://www.googleapis.com/auth/cryptauth"
    static let authURL = URL(string: "https://android.clients.google.com/auth")!

    struct AuthError: Error { let message: String }

    static func token(email: String, masterToken: String, service: String) async throws -> String {
        let params = [
            "accountType": "HOSTED_OR_GOOGLE",
            "Email": email,
            "has_permission": "1",
            "EncryptedPasswd": masterToken,
            "service": service,
            "source": "android",
            "androidId": androidId,
            "app": gmsPackage,
            "client_sig": gmsSig,
            "device_country": "us",
            "operatorCountry": "us",
            "lang": "en",
            "sdk_version": "17",
        ]
        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("GoogleAuth/1.4", forHTTPHeaderField: "User-Agent")
        req.httpBody = Form.encode(params)

        let (data, _) = try await URLSession.shared.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("Auth=") {
            return String(line.dropFirst("Auth=".count))
        }
        throw AuthError(message: "no Auth token in response: \(text)")
    }

    static func cryptAuthToken(email: String, masterToken: String) async throws -> String {
        try await token(email: email, masterToken: masterToken, service: cryptauthScope)
    }
}
