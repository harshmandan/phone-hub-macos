#!/usr/bin/env python3
"""TEST: upload our host metadata WITH a fabricated CROS_SOFT_BIND_CERT_CHAIN in
BetterTogetherDeviceMetadata.attestation_data (field 5), to learn whether GMS
validates the cert chain (→ hard wall) or merely checks the field is present
(→ a fake would pass). Self-signed; it does NOT chain to Google's CA.

Usage: ./upload_with_attestation.py <email> <master_token>
"""
import base64, datetime, json, sys
import gpsoauth
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

import pb
import securemessage as sm
from device_sync import post, SYNC_METADATA, BETTER_TOGETHER_GROUP
from probe_auth import ANDROID_ID, GMS_PACKAGE, GMS_SIG, CRYPTAUTH_SCOPE
from upload_host_metadata import get_or_make_seeds, beacon_seed, MAC_BT_ADDRESS


def fake_cert_chain() -> list:
    """A plausible-looking but self-signed soft-bind chain (leaf + CA), PEM."""
    now = datetime.datetime.utcnow()
    ca_key = ec.generate_private_key(ec.SECP256R1())
    ca_name = x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Chrome Device Soft Bind"),
                         x509.NameAttribute(NameOID.COMMON_NAME, "Local Authority")])
    ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
          .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=365))
          .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
          .sign(ca_key, hashes.SHA256()))
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    leaf_name = x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Chrome Device Soft Bind"),
                          x509.NameAttribute(NameOID.COMMON_NAME, "Cryptauth User Key")])
    leaf = (x509.CertificateBuilder().subject_name(leaf_name).issuer_name(ca_name)
            .public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now).not_valid_after(now + datetime.timedelta(hours=72))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                key_encipherment=False, data_encipherment=False, key_agreement=False,
                key_cert_sign=False, crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
            .sign(ca_key, hashes.SHA256()))
    return [leaf.public_bytes(serialization.Encoding.PEM),
            ca.public_bytes(serialization.Encoding.PEM)]


def metadata_with_attestation(ks, seeds) -> bytes:
    device_pub = base64.b64decode(ks["keys"]["DeviceSync:BetterTogether"]["keyMaterial"])
    out = pb.bytes_(1, device_pub) + pb.string(2, "Chromebook")
    for s in seeds:
        out += pb.message(3, beacon_seed(s))
    out += pb.string(4, MAC_BT_ADDRESS)
    # AttestationData: type(1)=CROS_SOFT_BIND_CERT_CHAIN=1, certificates(2) repeated.
    att = pb.varint(1, 1)
    for cert in fake_cert_chain():
        att += pb.bytes_(2, cert)
    out += pb.message(5, att)
    return out


def main():
    email, master = sys.argv[1], sys.argv[2]
    ks = json.load(open("device_keys.json"))
    gpk_b64 = ks["groupKey"]["publicGeneric"]
    group_pub = sm._parse_generic_public_key(base64.b64decode(gpk_b64))
    token = gpsoauth.perform_oauth(email, master, ANDROID_ID, service=CRYPTAUTH_SCOPE,
                                   app=GMS_PACKAGE, client_sig=GMS_SIG).get("Auth")
    seeds = get_or_make_seeds(ks)
    enc = sm.encrypt(metadata_with_attestation(ks, seeds), group_pub)
    body = {"context": {"group": BETTER_TOGETHER_GROUP,
                        "clientMetadata": {"invocationReason": "FEATURE_TOGGLED"},
                        "deviceId": ks["instanceId"], "deviceIdToken": ks["gcmToken"]},
            "groupPublicKey": gpk_b64, "encryptedMetadata": base64.b64encode(enc).decode(),
            "needGroupPrivateKey": False}
    code, text = post(SYNC_METADATA, token, body)
    print("syncMetadata HTTP", code)
    if code == 200:
        print(">>> uploaded host metadata WITH fabricated attestation_data (field 5)")


if __name__ == "__main__":
    main()
