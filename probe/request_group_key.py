#!/usr/bin/env python3
"""Join the Better Together group with the group's REAL key (CryptAuth v2 SyncMetadata).

device_sync.py wrongly assumed we create the group key; the group already had one
(made by a phone), so our metadata was encrypted to a stray key and ignored. This
does what Chromium's metadata syncer does for a device without the group private key:
encrypt our metadata to the server's group PUBLIC key and set needGroupPrivateKey,
so a device that holds the key (the phone) shares it with us on its next sync.

When the response carries encryptedGroupPrivateKey, it is decrypted with our
DeviceSync:BetterTogether private key and saved to device_keys.json as groupKey
(the old stray key is kept as groupKeyStray).

Usage:
    ./request_group_key.py <email> <master_token> [bt_address]
"""
import base64
import json
import os
import sys

import gpsoauth
from cryptography.hazmat.primitives import serialization

import pb
import securemessage as sm
from device_sync import post, SYNC_METADATA, BETTER_TOGETHER_GROUP
from probe_auth import ANDROID_ID, GMS_PACKAGE, GMS_SIG, CRYPTAUTH_SCOPE

MAC_BT_ADDRESS = "AA:BB:CC:DD:EE:FF"


def metadata(ks: dict, bt_address: str) -> bytes:
    # BetterTogetherDeviceMetadata: public_key(1), no_pii_device_name(2),
    # bluetooth_public_address(4).
    device_pub = base64.b64decode(ks["keys"]["DeviceSync:BetterTogether"]["keyMaterial"])
    return pb.bytes_(1, device_pub) + pb.string(2, "Chromebook") + pb.string(4, bt_address)


def sync(token: str, ks: dict, body_extra: dict) -> dict:
    body = {"context": {"group": BETTER_TOGETHER_GROUP,
                        "clientMetadata": {"invocationReason": "INITIALIZATION"},
                        "deviceId": ks["instanceId"], "deviceIdToken": ks["gcmToken"]}}
    body.update(body_extra)
    code, text = post(SYNC_METADATA, token, body)
    if code != 200:
        print("HTTP", code, text[:400])
        sys.exit(1)
    return json.loads(text)


def main() -> None:
    if len(sys.argv) not in (3, 4):
        print(__doc__)
        sys.exit(1)
    email, master = sys.argv[1], sys.argv[2]
    bt_address = sys.argv[3] if len(sys.argv) == 4 else MAC_BT_ADDRESS
    ks = json.load(open("device_keys.json"))
    token = gpsoauth.perform_oauth(email, master, ANDROID_ID, service=CRYPTAUTH_SCOPE,
                                   app=GMS_PACKAGE, client_sig=GMS_SIG).get("Auth")
    if not token:
        print("no cryptauth token")
        sys.exit(1)

    # 1) The group's public key. The server 400s a sync without key + metadata, so
    #    take it from a previous syncMetadata reply (GROUP_PUBLIC_KEY env var).
    group_pub_b64 = os.environ.get("GROUP_PUBLIC_KEY")
    if not group_pub_b64:
        print("set GROUP_PUBLIC_KEY to the groupPublicKey from a device_sync.py reply")
        sys.exit(1)
    group_pub = sm._parse_generic_public_key(base64.b64decode(group_pub_b64))
    print("server group public key:", group_pub_b64[:40] + "…")

    # 2) Upload our metadata encrypted to the REAL group key, and ask for the private key.
    enc = sm.encrypt(metadata(ks, bt_address), group_pub)
    resp = sync(token, ks, {"groupPublicKey": group_pub_b64,
                            "encryptedMetadata": base64.b64encode(enc).decode(),
                            "needGroupPrivateKey": True})
    with open("last_sync_response.json", "w") as f:
        json.dump(resp, f, indent=2)

    devices = resp.get("encryptedMetadata", [])
    print(f"{len(devices)} devices; with metadata: "
          f"{[d['deviceId'] for d in devices if d.get('encryptedMetadata')]}")
    me = [d for d in devices if d.get("deviceId") == ks["instanceId"]]
    print("our entry:", {k: v for k, v in (me[0] if me else {}).items() if k != "devicePublicKey"})

    egpk = resp.get("encryptedGroupPrivateKey")
    if not egpk:
        print(">>> No group private key yet. A device holding it (the phone) shares it on its next sync.")
        return
    print("encryptedGroupPrivateKey from", egpk.get("senderDeviceId"))
    dev_priv = serialization.load_pem_private_key(
        ks["keys"]["DeviceSync:BetterTogether"]["privatePem"].encode(), None)
    raw = sm.decrypt(base64.b64decode(egpk["encryptedPrivateKey"]), dev_priv)
    ks.setdefault("groupKeyStray", ks.get("groupKey"))
    ks["groupKey"] = {"privateRawB64": base64.b64encode(raw).decode(),
                      "publicGeneric": group_pub_b64}
    json.dump(ks, open("device_keys.json", "w"), indent=2)
    print(f">>> Got the real group private key ({len(raw)} bytes) — saved to device_keys.json.")


if __name__ == "__main__":
    main()
