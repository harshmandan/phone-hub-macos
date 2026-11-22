#!/usr/bin/env python3
"""List the account's Better Together device registry (DeviceSync SyncMetadata).

This is the real proof that enrollment took: SyncMetadata returns every device
in the account's Better Together group, each with device_id, device_name and
public key in the clear (only the per-device metadata blob is encrypted). If the
enrolled Mac shows up here, it is registered for the phone features.

Usage:
    ./device_sync.py <email> <master_token>

Expectations:
  - The Mac (this enrollment) should appear.
  - A phone appears ONLY if that same account is signed in on a phone with
    Phone Hub / Better Together set up. The throwaway account has no phone, so
    seeing just the Mac is the expected pass here.

Caveat: SyncMetadata authenticates the caller by device_id + device_id_token
(a GCM token). Our GCM registration is still the shaky part; if this returns an
auth error about the device/token, real GCM registration is the prerequisite to
fix first.
"""
import json
import sys
import urllib.request

import gpsoauth

from probe_auth import ANDROID_ID, GMS_PACKAGE, GMS_SIG, CRYPTAUTH_SCOPE
from probe_enroll import API_KEY, ANDROID_CERT

HOST = "https://cryptauthdevicesync.googleapis.com"
SYNC_METADATA = HOST + "/v1:syncMetadata"

# kCryptAuthDeviceSyncBetterTogetherKeyName
BETTER_TOGETHER_GROUP = "DeviceSync:BetterTogether"


def post(url: str, auth_token: str, body: dict) -> tuple[int, str]:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "x-goog-api-key": API_KEY,
            "x-android-package": "com.google.android.gms",
            "x-android-cert": ANDROID_CERT,
            "Authorization": f"Bearer {auth_token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(req)
        return resp.getcode(), resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    email, master_token = sys.argv[1], sys.argv[2]

    res = gpsoauth.perform_oauth(
        email, master_token, ANDROID_ID,
        service=CRYPTAUTH_SCOPE, app=GMS_PACKAGE, client_sig=GMS_SIG,
    )
    auth_token = res.get("Auth")
    if not auth_token:
        print("could not get cryptauth token:", res)
        sys.exit(1)

    # Reuse the enrolled device identity saved by probe_enroll.
    try:
        with open("device_keys.json") as f:
            ks = json.load(f)
        instance_id, gcm_token = ks["instanceId"], ks["gcmToken"]
    except FileNotFoundError:
        print("No device_keys.json — run probe_enroll.py first.")
        sys.exit(1)

    body = {
        "context": {
            "group": BETTER_TOGETHER_GROUP,
            "clientMetadata": {"invocationReason": "INITIALIZATION"},
            "deviceId": instance_id,
            "deviceIdToken": gcm_token,
        },
        # NOTE: 400 until group metadata is added here —
        #   "groupPublicKey": <group key pair public>,
        #   "encryptedMetadata": <BetterTogetherDeviceMetadata, encrypted>,
        # per cryptauth_metadata_syncer_impl.cc. See docs/devicesync.md step 3.
        "needGroupPrivateKey": True,
    }

    print("=== syncMetadata ===")
    code, text = post(SYNC_METADATA, auth_token, body)
    print("HTTP", code)
    print(text)
    print()

    if code != 200:
        print(">>> Not 200. If it names device/token/auth, real GCM is needed first.")
        return

    try:
        packets = json.loads(text).get("encryptedMetadata", [])
    except json.JSONDecodeError:
        print(">>> 200 but could not parse; inspect above.")
        return

    print(f">>> {len(packets)} device(s) in the Better Together group:")
    for p in packets:
        print(f"  - id={p.get('deviceId')}  name={p.get('deviceName')!r}"
              f"  haskey={bool(p.get('devicePublicKey'))}")
    print()
    print("The Mac listed here = it is in the registry the phone reads.")
    print("No phone listed = no phone is on this account (expected for throwaway).")


if __name__ == "__main__":
    main()
