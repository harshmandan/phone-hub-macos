#!/usr/bin/env python3
"""Link our enrolled Chromebook to the phone (multidevice setup).

Enables BETTER_TOGETHER_HOST on the phone and BETTER_TOGETHER_CLIENT on us, via
BatchSetFeatureStatuses — the protocol behind the Chromebook "Set up" flow.
After this the phone should start advertising over BLE and sharing full metadata.

Run probe_enroll.py first (it saves our identity to device_keys.json).

Usage:
    ./link.py <email> <master_token> <phone_device_id>
"""
import json
import sys
import urllib.request

import gpsoauth

from probe_auth import ANDROID_ID, GMS_PACKAGE, GMS_SIG, CRYPTAUTH_SCOPE
from probe_enroll import API_KEY, ANDROID_CERT

HOST = "https://cryptauthdevicesync.googleapis.com"
BATCH_SET = HOST + "/v1:batchSetFeatureStatuses"
GROUP = "DeviceSync:BetterTogether"


def post(url, token, body):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={
            "x-goog-api-key": API_KEY,
            "x-android-package": "com.google.android.gms",
            "x-android-cert": ANDROID_CERT,
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }, method="POST")
    try:
        r = urllib.request.urlopen(req)
        return r.getcode(), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    email, master_token, phone_id = sys.argv[1], sys.argv[2], sys.argv[3]

    with open("device_keys.json") as f:
        ks = json.load(f)
    our_id, our_token = ks["instanceId"], ks["gcmToken"]

    token = gpsoauth.perform_oauth(
        email, master_token, ANDROID_ID,
        service=CRYPTAUTH_SCOPE, app=GMS_PACKAGE, client_sig=GMS_SIG).get("Auth")
    if not token:
        print("no cryptauth token")
        sys.exit(1)

    body = {
        "context": {
            "group": GROUP,
            "clientMetadata": {"invocationReason": "FEATURE_TOGGLED"},
            "deviceId": our_id,
            "deviceIdToken": our_token,
        },
        "deviceFeatureStatuses": [
            {"deviceId": phone_id, "featureStatuses": [
                {"featureType": "BETTER_TOGETHER_HOST", "enabled": True, "enableExclusively": True}]},
            {"deviceId": our_id, "featureStatuses": [
                {"featureType": "BETTER_TOGETHER_CLIENT", "enabled": True, "enableExclusively": False}]},
        ],
    }

    print("=== batchSetFeatureStatuses (enable host on phone) ===")
    code, text = post(BATCH_SET, token, body)
    print("HTTP", code)
    print(text)
    if code == 200:
        print()
        print(">>> Host enable sent. Check the phone — it may show a permission")
        print(">>> prompt to approve. Then re-run device_sync.py to see if it's linked.")


if __name__ == "__main__":
    main()
