#!/usr/bin/env python3
"""Enable PHONE_HUB_HOST on the phone + PHONE_HUB_CLIENT on our Chromebook via
batchSetFeatureStatuses (same path link.py uses for BETTER_TOGETHER). Test
whether the phone then registers a phone_hub message processor (flips the
featureToConnectionModeMap phone_hub entry 768 -> 8).

Non-exclusive, so it leaves magic_tether / easy_unlock untouched.

Usage: ./enable_phonehub.py <email> <master_token> <phone_device_id>
"""
import json, sys
import gpsoauth
from probe_auth import ANDROID_ID, GMS_PACKAGE, GMS_SIG, CRYPTAUTH_SCOPE
from link import post, BATCH_SET, GROUP


def main():
    email, master, phone_id = sys.argv[1], sys.argv[2], sys.argv[3]
    ks = json.load(open("device_keys.json"))
    our_id, our_token = ks["instanceId"], ks["gcmToken"]
    token = gpsoauth.perform_oauth(email, master, ANDROID_ID, service=CRYPTAUTH_SCOPE,
                                   app=GMS_PACKAGE, client_sig=GMS_SIG).get("Auth")
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
