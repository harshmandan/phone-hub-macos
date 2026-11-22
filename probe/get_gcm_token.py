#!/usr/bin/env python3
"""Get a GCM instance-id token for CryptAuth, as a Chromebook would.

Two steps:
  1. GCM check-in (as a Chrome browser) -> androidId + securityToken.
     Reuses firebase-messaging, which already checks in as Chrome.
  2. Register the CryptAuth app id for a GCM token.

This is the least-certain part of the probe. The check-in is solid; the
register params mirror microG's InstanceID registration with Chrome's app id,
but Google may want them slightly different. If syncKeys later returns a
GCM-specific error, this is the file to adjust.

Prints:  instance_id  gcm_token   (feed both to probe_enroll.py)

Usage:
    ./get_gcm_token.py
"""
import asyncio
import base64
import os
import sys
import time

import aiohttp
from firebase_messaging.fcmregister import FcmRegister, FcmRegisterConfig

GCM_REGISTER_URL = "https://android.clients.google.com/c2dm/register3"

# CryptAuth GCM identity, from Chromium gcm_constants.cc:
#   app id  com.google.chrome.cryptauth
#   sender  381449029288 (kCryptAuthGcmSenderId)
#   enrollment authorized entity 16502139086
CRYPTAUTH_APP = "com.google.chrome.cryptauth"
AUTHORIZED_ENTITY = "16502139086"


def generate_instance_id() -> str:
    """An InstanceID-shaped id. The backing key is never used (per microG)."""
    raw = bytearray(os.urandom(8))
    raw[0] = (112 + (raw[0] & 0x0F)) & 0xFF
    return base64.urlsafe_b64encode(bytes(raw)).decode("ascii").rstrip("=")


async def checkin() -> dict:
    cfg = FcmRegisterConfig(
        project_id="probe",
        app_id="probe",
        api_key="probe",
        messaging_sender_id=AUTHORIZED_ENTITY,
    )
    async with aiohttp.ClientSession() as session:
        reg = FcmRegister(cfg, http_client_session=session)
        opts = await reg.gcm_check_in()
    if not opts:
        raise RuntimeError("GCM check-in failed")
    return opts


def register(android_id: str, security_token: str, instance_id: str) -> str:
    import urllib.request
    import urllib.parse

    body = {
        "app": CRYPTAUTH_APP,
        "device": android_id,
        "sender": AUTHORIZED_ENTITY,
        "X-subtype": AUTHORIZED_ENTITY,
        "subtype": AUTHORIZED_ENTITY,
        "X-subscription": AUTHORIZED_ENTITY,
        "subscription": AUTHORIZED_ENTITY,
        "appid": instance_id,
        "scope": "GCM",
        "X-scope": "GCM",
        "osv": "29",
        "cliv": "iid-202414000",
    }
    data = urllib.parse.urlencode(body).encode()
    # PHONE_REGISTRATION_ERROR from register3 is commonly transient; retry.
    last = ""
    for _ in range(5):
        req = urllib.request.Request(
            GCM_REGISTER_URL,
            data=data,
            headers={
                "Authorization": f"AidLogin {android_id}:{security_token}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        last = urllib.request.urlopen(req).read().decode()
        if "token=" in last:
            return last.split("token=", 1)[1].strip()
        time.sleep(2)
    raise RuntimeError(f"GCM register failed: {last}")


def main() -> None:
    opts = asyncio.run(checkin())
    android_id = str(opts["androidId"])
    security_token = str(opts["securityToken"])
    instance_id = generate_instance_id()
    print("android_id:", android_id, file=sys.stderr)
    token = register(android_id, security_token, instance_id)
    # stdout: just the two values, space-separated, for easy copy
    print(instance_id, token)


if __name__ == "__main__":
    main()
