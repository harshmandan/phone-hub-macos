import Foundation

/// The ClientAppMetadata that claims the Mac is a Chromebook. Port of
/// `metadata.py`. Field numbers from microG's cryptauth protos.
enum ClientAppMetadata {
    static let deviceTypeChrome: UInt64 = 2
    static let featureBetterTogether: UInt64 = 2
    // BETTER_TOGETHER_CLIENT, EASY_UNLOCK_CLIENT, MAGIC_TETHER_CLIENT,
    // PHONE_HUB_CLIENT, PHONE_HUB_CAMERA_ROLL_CLIENT
    static let clientFeatures: [UInt64] = [2, 4, 6, 10, 16]

    static func packedVarints(_ field: Int, _ values: [UInt64]) -> Data {
        var body = Data()
        for v in values { body += Pb.varintBytes(v) }
        return Pb.tag(field, 2) + Pb.varintBytes(UInt64(body.count)) + body
    }

    static func featureMetadata() -> Data {
        let betterTogether = packedVarints(1, clientFeatures)
        return Pb.varint(1, featureBetterTogether) + Pb.bytes(2, betterTogether)
    }

    static func applicationSpecificMetadata(gcmToken: String) -> Data {
        var m = Data()
        m += Pb.bytes(1, Data(gcmToken.utf8))                        // gcm_registration_id
        m += Pb.varint(2, 1)                                         // notification_enabled
        m += Pb.bytes(3, Data("138.0.0.0".utf8))                     // device_software_version
        m += Pb.varint(4, 138000)                                    // device_software_version_code
        m += Pb.bytes(5, Data("com.google.chrome.cryptauth".utf8))   // device_software_package
        return m
    }

    /// Returns the base64url ClientAppMetadata string for the syncKeys body.
    static func build(instanceId: String, gcmToken: String, longDeviceId: String) -> String {
        var m = Data()
        m += Pb.message(1, applicationSpecificMetadata(gcmToken: gcmToken))
        m += Pb.bytes(2, Data(instanceId.utf8))          // instance_id
        m += Pb.bytes(3, Data(gcmToken.utf8))            // instance_id_token
        m += Pb.bytes(5, Data(longDeviceId.utf8))        // long_device_id
        m += Pb.bytes(6, Data("en-US".utf8))             // locale
        m += Pb.bytes(7, Data("15917.0.0".utf8))         // device_os_version
        m += Pb.bytes(12, Data("eve".utf8))              // device_model
        m += Pb.bytes(13, Data("Google".utf8))           // device_manufacturer
        m += Pb.varint(14, deviceTypeChrome)             // device_type = CHROME
        m += Pb.varint(15, 1)                            // using_secure_screenlock
        m += Pb.varint(18, 1)                            // bluetooth_radio_supported
        m += Pb.varint(20, 1)                            // ble_radio_supported
        m += Pb.message(23, featureMetadata())           // feature_metadata
        return m.base64url
    }
}
