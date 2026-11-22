"""Build the ClientAppMetadata protobuf that claims the Mac is a Chromebook.

This is the one real change from microG's Android flow: device_type = CHROME and
the Better Together feature list a Chromebook advertises. Field numbers come from
microG's cryptauth_client_app_metadata.proto and
cryptauth_better_together_feature_metadata.proto.
"""
import base64

import pb

# ClientAppMetadata.DeviceType
DEVICE_TYPE_CHROME = 2

# FeatureMetadata.Feature
FEATURE_BETTER_TOGETHER = 2

# BetterTogetherFeatureMetadata.FeatureName — the client-side features a
# Chromebook offers. Hosts (…_HOST) live on the phone; we are the client.
BETTER_TOGETHER_CLIENT = 2
EASY_UNLOCK_CLIENT = 4
MAGIC_TETHER_CLIENT = 6
PHONE_HUB_CLIENT = 10
PHONE_HUB_CAMERA_ROLL_CLIENT = 16

CLIENT_FEATURES = [
    BETTER_TOGETHER_CLIENT,
    EASY_UNLOCK_CLIENT,
    MAGIC_TETHER_CLIENT,
    PHONE_HUB_CLIENT,
    PHONE_HUB_CAMERA_ROLL_CLIENT,
]


def _better_together_metadata() -> bytes:
    # BetterTogetherFeatureMetadata { repeated FeatureName supported_features = 1 }
    return pb.packed_varints(1, CLIENT_FEATURES)


def _feature_metadata() -> bytes:
    # FeatureMetadata { feature_type = 1; metadata = 2 }
    return pb.varint(1, FEATURE_BETTER_TOGETHER) + pb.bytes_(
        2, _better_together_metadata()
    )


def _application_specific_metadata(gcm_token: str) -> bytes:
    # ApplicationSpecificMetadata
    return (
        pb.bytes_(1, gcm_token.encode("utf-8"))  # gcm_registration_id
        + pb.boolean(2, True)  # notification_enabled
        + pb.string(3, "138.0.0.0")  # device_software_version
        + pb.varint(4, 138000)  # device_software_version_code
        + pb.string(5, "com.google.chrome.cryptauth")  # device_software_package
    )


def build_client_app_metadata(
    instance_id: str, gcm_token: str, long_device_id: str
) -> str:
    """Return the base64url ClientAppMetadata string for the syncKeys body."""
    msg = (
        pb.message(1, _application_specific_metadata(gcm_token))
        + pb.string(2, instance_id)  # instance_id
        + pb.string(3, gcm_token)  # instance_id_token
        + pb.string(5, long_device_id)  # long_device_id (Chrome uses a UUID)
        + pb.string(6, "en-US")  # locale
        + pb.string(7, "15917.0.0")  # device_os_version (ChromeOS build)
        + pb.string(12, "eve")  # device_model (a Chromebook board name)
        + pb.string(13, "Google")  # device_manufacturer
        + pb.varint(14, DEVICE_TYPE_CHROME)  # device_type = CHROME
        + pb.boolean(15, True)  # using_secure_screenlock
        + pb.boolean(18, True)  # bluetooth_radio_supported
        + pb.boolean(20, True)  # ble_radio_supported
        + pb.message(23, _feature_metadata())  # feature_metadata
    )
    return base64.urlsafe_b64encode(msg).decode("ascii")
