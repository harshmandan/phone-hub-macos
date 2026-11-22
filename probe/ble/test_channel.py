"""Offline tests for the device-to-device encrypted channel.

Run: python3 test_channel.py  (from probe/ble/)
Covers the session-key agreement, SessionKeys split, and the SecureContext
channel. The identity-proof handshake needs a live phone and is not tested here.
"""
import hashlib
import os
import sys

sys.path.insert(0, "..")

from cryptography.hazmat.primitives.asymmetric import ec

import securemessage as sm
from session_keys import SessionKeys, hkdf, KSALT
from secure_context import SecureContext


def test_symmetric_securemessage():
    key = os.urandom(32)
    blob = sm.create(key, b"payload", public_metadata=b"meta")
    pt, meta = sm.unwrap(key, blob)
    assert pt == b"payload" and meta == b"meta"
    bad = bytearray(blob); bad[-1] ^= 1
    try:
        sm.unwrap(key, bytes(bad)); assert False
    except ValueError:
        pass


def test_ecies_still_works():
    g = ec.generate_private_key(ec.SECP256R1())
    assert sm.decrypt(sm.encrypt(b"ecies", g.public_key()), g) == b"ecies"


def test_key_agreement_and_channel():
    init = ec.generate_private_key(ec.SECP256R1())
    resp = ec.generate_private_key(ec.SECP256R1())
    root_i = hashlib.sha256(init.exchange(ec.ECDH(), resp.public_key())).digest()
    root_r = hashlib.sha256(resp.exchange(ec.ECDH(), init.public_key())).digest()
    assert root_i == root_r

    sk = SessionKeys(root_i)
    assert sk.initiator != sk.responder and len(sk.initiator) == 32

    mac = SecureContext(sk, "initiator")
    phone = SecureContext(sk, "responder")
    assert phone.decode(mac.encode(b"hello from mac")) == b"hello from mac"
    assert phone.decode(mac.encode(b"second")) == b"second"
    assert mac.decode(phone.encode(b"hi from phone")) == b"hi from phone"
    old = mac.encode(b"x"); phone.decode(old)
    try:
        phone.decode(old); assert False  # replay
    except ValueError:
        pass


def test_hkdf_rfc5869():
    ikm = b"\x0b" * 22
    salt = bytes(range(0x00, 0x0d))
    info = bytes(range(0xf0, 0xfa))
    assert hkdf(ikm, salt, info, 42).hex().startswith("3cb25f25faacd57a90434f64d0362f2a")


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
    print("all passed")
