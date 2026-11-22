#!/usr/bin/env python3
"""Stage 2: does CryptAuth accept this Mac as a Chrome device?

This is gate #2, the real unknown. It sends syncKeys + enrollKeys with
device_type = CHROME and the Phone Hub feature list. Run stage 1 first.

Usage:
    ./probe_enroll.py <email> <master_token>

It will:
  1. get a fresh cryptauth token from the master token
  2. get a GCM token (get_gcm_token.py)
  3. POST v1:syncKeys  with the CHROME ClientAppMetadata
  4. POST v1:enrollKeys with the returned session id

Reading the result is in the README. Short version:
  - syncKeys 200 with randomSessionId -> CHROME ACCEPTED (gate 2 passed)
  - syncKeys error naming device/metadata -> CHROME REJECTED (gate 2 failed)
  - syncKeys error naming gcm/registration -> inconclusive, fix get_gcm_token.py
"""
import json
import sys
import urllib.request
import uuid

import gpsoauth

from metadata import build_client_app_metadata
from probe_auth import ANDROID_ID, GMS_PACKAGE, GMS_SIG, CRYPTAUTH_SCOPE

BASE = "https://cryptauthenrollment.googleapis.com/"
SYNC_KEYS = BASE + "v1:syncKeys"
ENROLL_KEYS = BASE + "v1:enrollKeys"

# From microG (cryptauth_requests).
API_KEY = "AIzaSyAP-gfH3qvi6vgHZbSYwQ_XHqV_mXHhzIk"
ANDROID_CERT = "58E1C4133F7441EC3D2C270270A14802DA47BA0E"


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


def get_cryptauth_token(email: str, master_token: str) -> str:
    res = gpsoauth.perform_oauth(
        email, master_token, ANDROID_ID,
        service=CRYPTAUTH_SCOPE, app=GMS_PACKAGE, client_sig=GMS_SIG,
    )
    token = res.get("Auth")
    if not token:
        print("could not get cryptauth token (run probe_auth.py first):", res)
        sys.exit(1)
    return token


def get_gcm() -> tuple[str, str]:
    import subprocess

    out = subprocess.run(
        [sys.executable, "get_gcm_token.py"], capture_output=True, text=True
    )
    if out.returncode != 0:
        # GCM is the shaky part. The CHROME-acceptance question likely does not
        # need a valid token, so fall through with a placeholder and let the
        # syncKeys response tell us whether GCM is actually required.
        print("GCM token step failed; using a placeholder to still test CHROME:")
        print(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "")
        import uuid as _uuid

        return "placeholder-iid", "placeholder-gcm-token-" + _uuid.uuid4().hex
    instance_id, token = out.stdout.strip().split(" ", 1)
    return instance_id, token


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    email, master_token = sys.argv[1], sys.argv[2]

    auth_token = get_cryptauth_token(email, master_token)
    instance_id, gcm_token = get_gcm()
    long_device_id = str(uuid.uuid4())

    client_app_metadata = build_client_app_metadata(
        instance_id, gcm_token, long_device_id
    )

    sync_body = {
        "applicationName": "com.google.android.gms",
        "clientVersion": "1.0.0",
        "syncSingleKeyRequests": [
            {"keyName": "PublicKey", "keyHandles": "ZGV2aWNlX2tleQo="}
        ],
        "clientMetadata": {"invocationReason": "NEW_ACCOUNT"},
        "clientAppMetadata": client_app_metadata,
    }

    print("=== syncKeys ===")
    code, text = post(SYNC_KEYS, auth_token, sync_body)
    print("HTTP", code)
    print(text)
    print()

    if code != 200:
        print(">>> GATE 2 result: syncKeys did not return 200.")
        print(">>> If the error mentions device_type / metadata / CHROME -> REJECTED.")
        print(">>> If it mentions gcm / registration id -> fix get_gcm_token.py and retry.")
        return

    try:
        session_id = json.loads(text)["randomSessionId"]
    except (KeyError, json.JSONDecodeError):
        print(">>> 200 but no randomSessionId; inspect the body above.")
        return

    print(">>> GATE 2 PASSED: CHROME enrollment accepted. session:", session_id)
    print()
    print("=== enrollKeys ===")
    enroll_body = {
        "randomSessionId": session_id,
        "clientEphemeralDh": "",
        "enrollSingleKeyRequests": [],
    }
    code, text = post(ENROLL_KEYS, auth_token, enroll_body)
    print("HTTP", code)
    print(text)
    print()
    print("Now check the phone: Settings > Google > Devices & sharing.")
    print("A new Chromebook there = the whole gate passed. Build it.")


if __name__ == "__main__":
    main()
