#!/usr/bin/env python3
"""Upload our host (Chromebook) BetterTogetherDeviceMetadata WITH beacon_seeds.

request_group_key.py uploaded only public_key + name + bt_address. A real
Chromebook host also advertises beacon_seeds (field 3). GMS logs
"[DeviceMetadataFetcher] Missing device metadata packets" and will not treat
the host as connectable (won't advertise its own EID / won't listen) until it
holds a complete, decryptable metadata packet for us. This adds the seeds.

Metadata is encrypted to the group's public key (we hold the matching private
key, so needGroupPrivateKey=False). Beacon seeds are generated once and kept in
device_keys.json under "macBeaconSeeds" so they stay stable.

Usage:
    ./upload_host_metadata.py <email> <master_token>
"""
import base64
import json
import os
import sys
import time

import pb
import securemessage as sm
from device_sync import SYNC_METADATA, BETTER_TOGETHER_GROUP
from probe_common import cryptauth_token, load_keys, post

MAC_BT_ADDRESS = os.environ.get("MAC_BT_ADDRESS", "AA:BB:CC:DD:EE:FF")  # set to your Mac's Bluetooth MAC
SEED_WINDOW_MS = 14 * 24 * 60 * 60 * 1000  # 14 days, matching the phone's seeds
NUM_SEEDS = 4


def get_or_make_seeds(ks: dict) -> list:
    seeds = ks.get("macBeaconSeeds")
    if seeds:
        return seeds
    now = int(time.time() * 1000)
    start = now - SEED_WINDOW_MS  # first window already active
    seeds = []
    for _ in range(NUM_SEEDS):
        seeds.append({"dataHex": os.urandom(32).hex(),
                      "startMs": start, "endMs": start + SEED_WINDOW_MS})
        start += SEED_WINDOW_MS
    ks["macBeaconSeeds"] = seeds
    return seeds


def beacon_seed(seed: dict) -> bytes:
    # BeaconSeed: data(1), start_time_millis(2), end_time_millis(3)
    return (pb.bytes_(1, bytes.fromhex(seed["dataHex"]))
            + pb.varint(2, seed["startMs"])
            + pb.varint(3, seed["endMs"]))


def metadata(ks: dict, seeds: list, attestation: bytes = None) -> bytes:
    # BetterTogetherDeviceMetadata: public_key(1), no_pii_device_name(2),
    # beacon_seeds(3, repeated), bluetooth_public_address(4), attestation_data(5).
    device_pub = base64.b64decode(ks["keys"]["DeviceSync:BetterTogether"]["keyMaterial"])
    out = pb.bytes_(1, device_pub) + pb.string(2, "Chromebook")
    for s in seeds:
        out += pb.message(3, beacon_seed(s))
    out += pb.string(4, MAC_BT_ADDRESS)
    if attestation is not None:
        out += pb.message(5, attestation)
    return out


def sync_metadata_body(ks: dict, enc: bytes, group_pub_b64: str) -> dict:
    return {"context": {"group": BETTER_TOGETHER_GROUP,
                        "clientMetadata": {"invocationReason": "FEATURE_TOGGLED"},
                        "deviceId": ks["instanceId"], "deviceIdToken": ks["gcmToken"]},
            "groupPublicKey": group_pub_b64,
            "encryptedMetadata": base64.b64encode(enc).decode(),
            "needGroupPrivateKey": False}


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    email, master = sys.argv[1], sys.argv[2]
    ks = load_keys()
    group_pub_b64 = ks["groupKey"]["publicGeneric"]
    group_pub = sm._parse_generic_public_key(base64.b64decode(group_pub_b64))

    token = cryptauth_token(email, master)
    if not token:
        print("no cryptauth token")
        sys.exit(1)

    seeds = get_or_make_seeds(ks)
    enc = sm.encrypt(metadata(ks, seeds), group_pub)
    body = sync_metadata_body(ks, enc, group_pub_b64)
    code, text = post(SYNC_METADATA, token, body)
    print("syncMetadata HTTP", code)
    if code != 200:
        print(text[:400]); sys.exit(1)
    json.dump(ks, open("device_keys.json", "w"), indent=2)  # persist seeds
    resp = json.loads(text)
    devs = resp.get("encryptedMetadata", [])
    print(f"{len(devs)} devices; with metadata: {[d['deviceId'] for d in devs if d.get('encryptedMetadata')]}")
    print(f">>> uploaded host metadata with {len(seeds)} beacon seeds + bt {MAC_BT_ADDRESS}")
    print(">>> now push a sync (link.py) so the phone re-fetches it.")


if __name__ == "__main__":
    main()
