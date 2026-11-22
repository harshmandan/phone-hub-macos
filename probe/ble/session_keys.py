"""Session keys for the device-to-device encrypted channel.

After the handshake agrees a root symmetric key, each direction gets its own
AES key via HKDF. Initiator encrypts with the "initiator" key; responder with
the "responder" key; each decrypts with the other's.

From chromeos/ash/services/secure_channel/session_keys.cc.
"""
import hashlib
import hmac

# session_keys.cc kSalt
KSALT = bytes([
    0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83, 0x46, 0xCA, 0x1C,
    0xEE, 0x8D, 0x39, 0x09, 0xB9, 0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D,
    0x4A, 0xB3, 0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10,
])
KEY_SIZE = 32


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int = KEY_SIZE) -> bytes:
    """RFC 5869 HKDF-SHA256."""
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm = b""
    t = b""
    counter = 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        okm += t
        counter += 1
    return okm[:length]


class SessionKeys:
    def __init__(self, root_symmetric_key: bytes):
        self.initiator = hkdf(root_symmetric_key, KSALT, b"initiator")
        self.responder = hkdf(root_symmetric_key, KSALT, b"responder")
