#!/usr/bin/env python3
"""Enable PHONE_HUB_HOST on the phone + PHONE_HUB_CLIENT on our Chromebook via
batchSetFeatureStatuses (same path link.py uses for BETTER_TOGETHER). Test
whether the phone then registers a phone_hub message processor (flips the
featureToConnectionModeMap phone_hub entry 768 -> 8).

Non-exclusive, so it leaves magic_tether / easy_unlock untouched.

Usage: ./enable_phonehub.py <email> <master_token> <phone_device_id>
"""
import sys
from link import BATCH_SET, GROUP
from probe_common import cryptauth_token, load_keys, post


def main():
    email, master, phone_id = sys.argv[1], sys.argv[2], sys.argv[3]
    ks = load_keys()
    our_id, our_token = ks["instanceId"], ks["gcmToken"]
    token = cryptauth_token(email, master)
    if not token:
        print("no cryptauth token"); sys.exit(1)
    body = {
        "context": {"group": GROUP, "clientMetadata": {"invocationReason": "FEATURE_TOGGLED"},
                    "deviceId": our_id, "deviceIdToken": our_token},
        "deviceFeatureStatuses": [
            {"deviceId": phone_id, "featureStatuses": [
                {"featureType": "PHONE_HUB_HOST", "enabled": True, "enableExclusively": False},
                {"featureType": "PHONE_HUB_CAMERA_ROLL_HOST", "enabled": True, "enableExclusively": False}]},
            {"deviceId": our_id, "featureStatuses": [
                {"featureType": "PHONE_HUB_CLIENT", "enabled": True, "enableExclusively": False},
                {"featureType": "PHONE_HUB_CAMERA_ROLL_CLIENT", "enabled": True, "enableExclusively": False}]},
        ],
    }
    code, text = post(BATCH_SET, token, body)
    print("batchSetFeatureStatuses HTTP", code, text[:300])


if __name__ == "__main__":
    main()
