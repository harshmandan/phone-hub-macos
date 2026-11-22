#!/usr/bin/env python3
"""Get a GCM InstanceID token for CryptAuth, the way GMS does.

Earlier this used firebase-messaging's Chrome-browser check-in, then registered
the CryptAuth app id, and got PHONE_REGISTRATION_ERROR: register3 for a GMS app
needs the device to have checked in as an Android device, not a Chrome browser.

So this does a real Android check-in (synthetic device profile, like microG),
then registers com.google.android.gms with the CryptAuth authorized entity.

Prints:  instance_id  gcm_token

Usage:
    ./get_gcm_token.py
"""
import base64
import os
import sys
import time
import urllib.parse
import urllib.request

import pb

CHECKIN_URL = "https://android.clients.google.com/checkin"
REGISTER_URL = "https://android.clients.google.com/c2dm/register3"

# CryptAuth enrollment authorized entity (Chromium gcm_constants.cc).
AUTHORIZED_ENTITY = "16502139086"
# GMS package + signing cert sha1 (microG CryptAuthRequests.CERTIFICATE).
GMS_PACKAGE = "com.google.android.gms"
GMS_CERT = "58e1c4133f7441ec3d2c270270a14802da47ba0e"
GMS_VERSION_CODE = "244433022"

# A plausible Android device profile for the check-in.
BUILD_FINGERPRINT = "google/sailfish/sailfish:8.1.0/OPM1.171019.011/4448085:user/release-keys"
BUILD_SDK = 27


def generate_instance_id() -> str:
    """An InstanceID-shaped id. The backing key is never used (per microG)."""
    raw = bytearray(os.urandom(8))
    raw[0] = (112 + (raw[0] & 0x0F)) & 0xFF
    return base64.urlsafe_b64encode(bytes(raw)).decode("ascii").rstrip("=")


def _checkin_request() -> bytes:
    # CheckinRequest (proto2). Field numbers from microG checkin.proto.
    build = pb.string(1, BUILD_FINGERPRINT) + pb.varint(10, BUILD_SDK)
    checkin = pb.message(1, build) + pb.varint(2, 0)  # build, lastCheckinMs
    return (
        pb.varint(2, 0)  # androidId = 0 (first check-in)
        + pb.message(4, checkin)  # checkin
        + pb.string(6, "en_US")  # locale
        + pb.varint(14, 3)  # version
        + pb.varint(20, 0)  # fragment (required)
    )


def _read_varint(d, i):
    s = r = 0
    while True:
        b = d[i]
        i += 1
        r |= (b & 0x7F) << s
        if not b & 0x80:
            return r, i
        s += 7


def _parse_checkin_response(data: bytes) -> tuple[int, int]:
    """Pull androidId (field 7) and securityToken (field 8), both fixed64."""
    android_id = security_token = None
    i = 0
    while i < len(data):
        key, i = _read_varint(data, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            _, i = _read_varint(data, i)
        elif wire == 1:
            val = int.from_bytes(data[i:i + 8], "little")
            if field == 7:
                android_id = val
            elif field == 8:
                security_token = val
            i += 8
        elif wire == 2:
            ln, i = _read_varint(data, i)
            i += ln
        elif wire == 5:
            i += 4
        else:
            raise ValueError(f"bad wire type {wire}")
    if android_id is None or security_token is None:
        raise RuntimeError("check-in response missing androidId/securityToken")
    return android_id, security_token


def checkin() -> tuple[int, int]:
    req = urllib.request.Request(
        CHECKIN_URL,
        data=_checkin_request(),
        headers={"Content-Type": "application/x-protobuf"},
    )
    body = urllib.request.urlopen(req).read()
    return _parse_checkin_response(body)


def register(android_id: int, security_token: int, instance_id: str) -> str:
    body = {
        "app": GMS_PACKAGE,
        "cert": GMS_CERT,
        "app_ver": GMS_VERSION_CODE,
        "gmsv": GMS_VERSION_CODE,
        "device": str(android_id),
        "sender": AUTHORIZED_ENTITY,
        "subtype": AUTHORIZED_ENTITY,
        "X-subtype": AUTHORIZED_ENTITY,
        "subscription": AUTHORIZED_ENTITY,
        "X-subscription": AUTHORIZED_ENTITY,
        "appid": instance_id,
        "scope": "GCM",
        "X-scope": "GCM",
        "osv": "27",
        "cliv": "iid-202414000",
    }
    data = urllib.parse.urlencode(body).encode()
    last = ""
    for _ in range(5):
        req = urllib.request.Request(
            REGISTER_URL,
            data=data,
            headers={
                "Authorization": f"AidLogin {android_id}:{security_token}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
        )
        last = urllib.request.urlopen(req).read().decode()
        if "token=" in last:
            return last.split("token=", 1)[1].strip()
        time.sleep(2)  # PHONE_REGISTRATION_ERROR is often transient
    raise RuntimeError(f"GCM register failed: {last}")


def main() -> None:
    android_id, security_token = checkin()
    print("android_id:", android_id, file=sys.stderr)
    instance_id = generate_instance_id()
    token = register(android_id, security_token, instance_id)
    print(instance_id, token)


if __name__ == "__main__":
    main()
