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

    /// NotifyPhoneSetupComplete (bootstrapState=2). Tells the phone setup succeeded.
    public static func bootstrapComplete() -> Data {
        let obj: [String: Any] = ["bootstrapState": 2]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// The phone's reply to bootstrapOptions. Chromium's writer emits the fields at
    /// the ROOT (no wrapper key) even though its reader looks for a wrapper, so
    /// accept both shapes.
    public static func parseBootstrapConfigurations(_ body: Data) -> [String: Any]? {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
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
