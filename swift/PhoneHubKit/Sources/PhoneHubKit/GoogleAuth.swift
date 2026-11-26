import Foundation

/// Exchange a durable master token for a scoped access token (the gpsoauth
/// perform_oauth step). Port of `probe_auth.py`.
public enum GoogleAuth {
    /// The device id the master token is bound to (must match the one used when
    /// the master token was minted).
    static let androidId = "3812d1b8e3a0c4f9"
    static let gmsPackage = "com.google.android.gms"
    static let gmsSig = "38918a453d07199354f8b19af05ec6562ced5788"
    static let cryptauthScope = "oauth2:https://www.googleapis.com/auth/cryptauth"
    static let authURL = URL(string: "https://android.clients.google.com/auth")!

    public struct AuthError: Error, LocalizedError { let message: String; public var errorDescription: String? { message } }

    /// Exchange the `oauth_token` captured from Google's Android EmbeddedSetup web
    /// login for a durable master token (aas_et/…), the same credential the probe
    /// tools take by hand. Returns (masterToken, email) — the /auth response carries
    /// the account email. No password ever passes through our code.
    public static func exchangeOAuthToken(_ oauthToken: String) async throws -> (masterToken: String, email: String) {
        let params = [
            "accountType": "HOSTED_OR_GOOGLE",
            "has_permission": "1",
            "add_account": "1",
            "service": "ac2dm",
            "source": "android",
            "androidId": androidId,
            "app": gmsPackage,
            "client_sig": gmsSig,
            "device_country": "us",
            "operatorCountry": "us",
            "lang": "en",
            "sdk_version": "17",
            "Token": oauthToken,
        ]
        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("GoogleAuth/1.4", forHTTPHeaderField: "User-Agent")
        req.httpBody = Form.encode(params)
        let (data, _) = try await URLSession.shared.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        var master: String?, email = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Token=") { master = String(line.dropFirst("Token=".count)) }
            if line.hasPrefix("Email=") { email = String(line.dropFirst("Email=".count)) }
        }
        guard let m = master else { throw AuthError(message: "sign-in didn't return a token: \(text.prefix(160))") }
        return (m, email)
    }

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
