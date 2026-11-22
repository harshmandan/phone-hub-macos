"""Build the group_public_key + encrypted_metadata for syncMetadata.

The first device in a Better Together group creates the group key pair, then
sends its own device metadata encrypted (securemessage) with that group key.
Later devices would fetch the group public key and request the private key; here
we are the first device, so we create and keep it.

See cryptauth_metadata_syncer_impl.cc (CreateGroupKey, sets group_public_key +
encrypted_metadata) and cryptauth_better_together_device_metadata.proto.
"""
import base64
import json
import os

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

import pb
import securemessage as sm

KEYS_FILE = "device_keys.json"


def _load() -> dict:
    with open(KEYS_FILE) as f:
        return json.load(f)


def _save(ks: dict) -> None:
    with open(KEYS_FILE, "w") as f:
        json.dump(ks, f, indent=2)


def _get_or_create_group_key(ks: dict) -> ec.EllipticCurvePrivateKey:
    g = ks.get("groupKey")
    if g:
        return serialization.load_pem_private_key(g["privatePem"].encode(), None)
    priv = ec.generate_private_key(ec.SECP256R1())
    ks["groupKey"] = {
        "privatePem": priv.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ).decode(),
    }
    _save(ks)
    return priv


def _random_bt_address() -> str:
    # "hex string with colons and capital" per the proto comment.
    return ":".join(f"{b:02X}" for b in os.urandom(6))


def _device_metadata(ks: dict) -> bytes:
    # BetterTogetherDeviceMetadata: public_key(1), no_pii_device_name(2),
    # bluetooth_public_address(4).
    device_pub = base64.b64decode(ks["keys"]["DeviceSync:BetterTogether"]["keyMaterial"])
    return (
        pb.bytes_(1, device_pub)
        + pb.string(2, "Chromebook")
        + pb.string(4, _random_bt_address())
    )


def build() -> tuple[str, str]:
    """Return (group_public_key_b64, encrypted_metadata_b64) for syncMetadata."""
    ks = _load()
    group_priv = _get_or_create_group_key(ks)
    group_pub = group_priv.public_key()

    plaintext = _device_metadata(ks)
    encrypted = sm.encrypt(plaintext, group_pub)
    group_public_key = sm.generic_public_key(group_pub)

    return (
        base64.b64encode(group_public_key).decode(),
        base64.b64encode(encrypted).decode(),
    )
