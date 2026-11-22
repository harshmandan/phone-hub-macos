#!/usr/bin/env python3
"""Share our group private key with the phone (CryptAuth ShareGroupPrivateKey).

Root cause (found via adb logcat): we own the Better Together group key but never
shared it, so the phone can't decrypt group metadata and disables Better Together.
This fixes it: ECIES-encrypt our group private key to the phone's device public
key and POST it, so the phone adopts the group key.

From cryptauth_group_private_key_sharer_impl.cc:
  group_public_key_hash = int64 little-endian of SHA256(group_public_key)[:8]
  encrypted_private_key  = ECIES(group_key.private_key, recipient device pubkey)

Usage:
    ./share_group_key.py <email> <master_token> <phone_device_id> [keyfmt]
      keyfmt: pkcs8 (default) | raw  — the group-private-key byte format to try
"""
import base64
import hashlib
import json
import struct
import sys
import urllib.request

import gpsoauth
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

import securemessage as sm
from probe_auth import ANDROID_ID, GMS_PACKAGE, GMS_SIG, CRYPTAUTH_SCOPE
from probe_enroll import API_KEY, ANDROID_CERT

HOST = "https://cryptauthdevicesync.googleapis.com"
SHARE = HOST + "/v1:shareGroupPrivateKey"
SYNC = HOST + "/v1:syncMetadata"
GROUP = "DeviceSync:BetterTogether"


def post(url, token, body):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"x-goog-api-key": API_KEY, "x-android-package": "com.google.android.gms",
                 "x-android-cert": ANDROID_CERT, "Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"}, method="POST")
    try:
        r = urllib.request.urlopen(req)
        return r.getcode(), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    email, master, phone_id = sys.argv[1], sys.argv[2], sys.argv[3]
    keyfmt = sys.argv[4] if len(sys.argv) > 4 else "pkcs8"

    ks = json.load(open("device_keys.json"))
    group_priv = serialization.load_pem_private_key(ks["groupKey"]["privatePem"].encode(), None)
    group_pub_generic = sm.generic_public_key(group_priv.public_key())
    group_hash = struct.unpack("<q", hashlib.sha256(group_pub_generic).digest()[:8])[0]

    token = gpsoauth.perform_oauth(email, master, ANDROID_ID, service=CRYPTAUTH_SCOPE,
                                   app=GMS_PACKAGE, client_sig=GMS_SIG).get("Auth")

    # fetch the phone's device_public_key from the group
    body = {"context": {"group": GROUP, "clientMetadata": {"invocationReason": "FEATURE_TOGGLED"},
                        "deviceId": ks["instanceId"], "deviceIdToken": ks["gcmToken"]},
            "groupPublicKey": base64.b64encode(group_pub_generic).decode(),
            "encryptedMetadata": base64.b64encode(
                sm.encrypt(_meta(ks), group_priv.public_key())).decode(),
            "needGroupPrivateKey": False}
    code, text = post(SYNC, token, body)
    pkt = next((p for p in (json.loads(text).get("encryptedMetadata", []) if code == 200 else [])
                if p.get("deviceId") == phone_id), None)
    if not pkt or not pkt.get("devicePublicKey"):
        print("could not get phone device public key; syncMetadata", code, text[:200]); sys.exit(1)
    phone_pub = sm._parse_generic_public_key(base64.b64decode(pkt["devicePublicKey"]))

    # the group private key bytes, in the chosen format
    if keyfmt == "raw":
        d = group_priv.private_numbers().private_value
        priv_bytes = d.to_bytes(32, "big")
    else:  # pkcs8 DER
        priv_bytes = group_priv.private_bytes(serialization.Encoding.DER,
                                              serialization.PrivateFormat.PKCS8,
                                              serialization.NoEncryption())

    encrypted = sm.encrypt(priv_bytes, phone_pub)  # ECIES to the phone's device key

    share = {"context": {"group": GROUP, "clientMetadata": {"invocationReason": "FEATURE_TOGGLED"},
                        "deviceId": ks["instanceId"], "deviceIdToken": ks["gcmToken"]},
             "encryptedGroupPrivateKeys": [{
                 "recipientDeviceId": phone_id, "senderDeviceId": ks["instanceId"],
                 "encryptedPrivateKey": base64.b64encode(encrypted).decode(),
                 "groupPublicKeyHash": str(group_hash)}]}
    print(f"=== shareGroupPrivateKey (keyfmt={keyfmt}, hash={group_hash}) ===")
    code, text = post(SHARE, token, share)
    print("HTTP", code, text[:300])


def _meta(ks):
    import pb
    device_pub = base64.b64decode(ks["keys"]["DeviceSync:BetterTogether"]["keyMaterial"])
    return pb.bytes_(1, device_pub) + pb.string(2, "Chromebook") + pb.string(4, "AA:BB:CC:DD:EE:FF")


if __name__ == "__main__":
    main()
