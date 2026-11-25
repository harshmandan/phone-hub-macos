import Foundation

/// Quick Start application-layer messages that ride on top of the UKEY2-secured
/// D2D channel (each is a JSON object serialized into a Nearby Connections BYTES
/// payload). Target = us (the "Chromebook"); we drive every request.
///
/// Sequence (from Chromium oobe_quick_start `connection.cc` + GMS decompile):
///   handshake → bootstrapOptions → (phone shows account picker) →
///   bootstrapConfigurations → secondDeviceAuthPayload (FIDO) → bootstrapState:2.
/// This file covers the first milestone: options + parsing the configurations.
public enum QuickStartMessages {

    /// RequestAccountInfo. Makes the phone surface its account picker and commit
    /// to the transfer. Constants from quick_start_requests.cc:
    /// accountRequirement=2 (single account), flowType=2 (target challenge),
    /// deviceType=7 (Chrome, the d2d device-type enum).
    public static func bootstrapOptions(deviceName: String = "Chromebook") -> Data {
        let landing = "intent:#Intent;action=com.google.android.gms.quickstart.LANDING_SCREEN;package=com.google.android.gms;end"
        let obj: [String: Any] = [
            "bootstrapOptions": [
                "accountRequirement": 2,
                "flowType": 2,
                "deviceType": 7,
                "deviceName": deviceName,
                "PostTransferAction": ["uri": landing],
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    // MARK: FIDO account transfer (quick_start_requests.cc)

    /// FIDO CollectedClientData as Chromium writes it (base::WriteJson sorts keys).
    public static func clientDataJSON(challengeB64url: String) -> String {
        "{\"challenge\":\"\(challengeB64url)\",\"crossOrigin\":false,\"origin\":\"https://accounts.google.com\",\"type\":\"webauthn.get\"}"
    }

    /// {"secondDeviceAuthPayload": {"fidoMessage": base64(ctap)}}
    private static func secondDeviceAuth(_ ctap: Data) -> Data {
        let obj: [String: Any] = ["secondDeviceAuthPayload": ["fidoMessage": ctap.base64EncodedString()]]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// CTAP2 authenticatorGetInfo (0x04).
    public static func getInfoRequest() -> Data { secondDeviceAuth(Data([0x04])) }

    /// CTAP2 authenticatorGetAssertion (0x02) + canonical CBOR
    /// {1: "google.com", 2: clientDataHash, 5: {"up": true, "uv": true}}.
    public static func assertionRequest(clientDataHash: Data) -> Data {
        precondition(clientDataHash.count == 32)
        var c = Data([0x02, 0xA3])
        c += Data([0x01, 0x6A]) + Data("google.com".utf8)
        c += Data([0x02, 0x58, 0x20]) + clientDataHash
        c += Data([0x05, 0xA2, 0x62]) + Data("up".utf8) + Data([0xF5, 0x62]) + Data("uv".utf8) + Data([0xF5])
        return secondDeviceAuth(c)
    }

    /// Decode a {"quickStartPayload": base64(json)} envelope; nil if not that shape.
    public static func quickStartPayload(_ body: Data) -> [String: Any]? {
        guard let o = try? JSONSerialization.jsonObject(with: sanitized(body)) as? [String: Any],
              let b64 = o["quickStartPayload"] as? String,
              let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let inner = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        return inner
    }

    /// Android's Base64.DEFAULT puts raw line breaks inside JSON strings, which
    /// strict JSON parsing rejects (Chromium parses leniently). Strip them.
    public static func sanitized(_ body: Data) -> Data {
        Data(body.filter { $0 != 0x0A && $0 != 0x0D })
    }

    /// NotifyPhoneSetupComplete (bootstrapState=2). Tells the phone setup succeeded.
    public static func bootstrapComplete() -> Data {
        let obj: [String: Any] = ["bootstrapState": 2]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// The phone's reply to bootstrapOptions. Chromium's writer emits the fields at
    /// the ROOT (no wrapper key) even though its reader looks for a wrapper, so
    /// accept both shapes.
    public static func parseBootstrapConfigurations(_ body: Data) -> [String: Any]? {
        guard let o = try? JSONSerialization.jsonObject(with: sanitized(body)) as? [String: Any] else { return nil }
        if let wrapped = o["bootstrapConfigurations"] as? [String: Any] { return wrapped }
        if o["email"] != nil || o["instanceId"] != nil || o["instance_id"] != nil { return o }
        return o
    }

    /// Best-effort label for a decoded app payload, for logging.
    public static func describe(_ body: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return "non-JSON \(body.count)B"
        }
        return "keys=\(o.keys.sorted())"
    }
}
