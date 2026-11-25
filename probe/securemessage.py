"""Google securemessage: the ECIES-style encryption CryptAuth uses.

Ported from google/securemessage (cpp/src/securemessage/crypto_ops.cc) and
cryptauth_ecies_encryptor_impl.cc. Scheme: AES-256-CBC + HMAC-SHA256, with the
symmetric master key from ECDH-then-SHA256.

Only the encrypt path is implemented (what we send). A decrypt is included so the
output can be round-trip verified in a unit test.
"""
import hashlib
import hmac
import os

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

import pb

# securemessage SigScheme / EncScheme
SIG_HMAC_SHA256 = 1
ENC_AES_256_CBC = 2

# CryptoOps::kSalt = SHA256("SecureMessage")
SALT = hashlib.sha256(b"SecureMessage").digest()

PUBLIC_KEY_TYPE_EC_P256 = 1


def _java_bigint_bytes(value: int) -> bytes:
    return value.to_bytes((value.bit_length() // 8) + 1, "big")


def generic_public_key(pub: ec.EllipticCurvePublicKey) -> bytes:
    n = pub.public_numbers()
    ec_p256 = pb.bytes_(1, _java_bigint_bytes(n.x)) + pb.bytes_(2, _java_bigint_bytes(n.y))
    return pb.varint(1, PUBLIC_KEY_TYPE_EC_P256) + pb.message(2, ec_p256)


def _hkdf(master: bytes, purpose: bytes) -> bytes:
    # securemessage HKDF: extract with SALT, expand one block (info || 0x01).
    prk = hmac.new(SALT, master, hashlib.sha256).digest()
    return hmac.new(prk, purpose + b"\x01", hashlib.sha256).digest()


def _master_key(private: ec.EllipticCurvePrivateKey,
                peer_pub: ec.EllipticCurvePublicKey) -> bytes:
    # KeyAgreementSha256: SHA256(ECDH shared secret X coordinate).
    shared = private.exchange(ec.ECDH(), peer_pub)
    return hashlib.sha256(shared).digest()


def encrypt(payload: bytes, group_pub: ec.EllipticCurvePublicKey) -> bytes:
    """Serialize a SecureMessage encrypting `payload` to `group_pub` (ECIES)."""
    session = ec.generate_private_key(ec.SECP256R1())
    master = _master_key(session, group_pub)
    return create(master, payload,
                  decryption_key_id=generic_public_key(session.public_key()))


def create(key: bytes, payload: bytes, public_metadata: bytes = b"",
           decryption_key_id: bytes = b"") -> bytes:
    """A SecureMessage encrypted+signed with one symmetric master `key`.

    Matches SecureMessageDelegate.CreateSecureMessage when the same key signs and
    encrypts (so no plaintext tag). enc/sig keys are derived from `key`.
    """
    enc_key = _hkdf(key, b"ENC:2")
    sig_key = _hkdf(key, b"SIG:1")

    iv = os.urandom(16)
    padder = PKCS7(128).padder()
    padded = padder.update(payload) + padder.finalize()
    enc = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).encryptor()
    body = enc.update(padded) + enc.finalize()

    header = pb.varint(1, SIG_HMAC_SHA256) + pb.varint(2, ENC_AES_256_CBC)
    if decryption_key_id:
        header += pb.bytes_(4, decryption_key_id)
    # SecureMessage Header proto: iv=5, public_metadata=6 (field 7 is
    # associated_data_length). Google reads iv from field 5.
    header += pb.bytes_(5, iv)
    if public_metadata:
        header += pb.bytes_(6, public_metadata)

    header_and_body = pb.bytes_(1, header) + pb.bytes_(2, body)
    signature = hmac.new(sig_key, header_and_body, hashlib.sha256).digest()
    return pb.bytes_(1, header_and_body) + pb.bytes_(2, signature)


def unwrap(key: bytes, secure_message: bytes) -> tuple[bytes, bytes]:
    """Verify + decrypt a symmetric SecureMessage. Returns (payload, public_metadata)."""
    sm = _read_fields(secure_message)
    header_and_body, signature = sm[1], sm[2]
    sig_key = _hkdf(key, b"SIG:1")
    expected = hmac.new(sig_key, header_and_body, hashlib.sha256).digest()
    if not hmac.compare_digest(expected, signature):
        raise ValueError("bad SecureMessage signature")
    hab = _read_fields(header_and_body)
    header, body = _read_fields(hab[1]), hab[2]
    enc_key = _hkdf(key, b"ENC:2")
    dec = Cipher(algorithms.AES(enc_key), modes.CBC(header[5])).decryptor()
    padded = dec.update(body) + dec.finalize()
    unpadder = PKCS7(128).unpadder()
    payload = unpadder.update(padded) + unpadder.finalize()
    return payload, header.get(6, b"")


# -- decrypt, for the round-trip self-test only --

def _rv(data: bytes, i: int):
    v = s = 0
    while True:
        b = data[i]; i += 1; v |= (b & 0x7f) << s
        if not b & 0x80:
            return v, i
        s += 7


def _read_fields(data: bytes) -> dict:
    out = {}
    i = 0
    while i < len(data):
        key, i = _rv(data, i)
        field, wire = key >> 3, key & 7
        if wire == 2:
            ln, i = _rv(data, i)
            out[field] = data[i:i + ln]; i += ln
        elif wire == 0:
            out[field], i = _rv(data, i)
        else:
            raise ValueError("unexpected wire type in test decoder")
    return out


def decrypt(secure_message: bytes, group_priv: ec.EllipticCurvePrivateKey) -> bytes:
    sm = _read_fields(secure_message)
    hab = _read_fields(sm[1])
    header, body = _read_fields(hab[1]), hab[2]
    session_pub = _parse_generic_public_key(header[4])
    master = _master_key(group_priv, session_pub)
    enc_key = _hkdf(master, b"ENC:2")
    iv = header[5]
    dec = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).decryptor()
    padded = dec.update(body) + dec.finalize()
    unpadder = PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


def _parse_generic_public_key(data: bytes) -> ec.EllipticCurvePublicKey:
    g = _read_fields(data)
    ecp = _read_fields(g[2])
    x = int.from_bytes(ecp[1], "big")
    y = int.from_bytes(ecp[2], "big")
    return ec.EllipticCurvePublicNumbers(x, y, ec.SECP256R1()).public_key()
