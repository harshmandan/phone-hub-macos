"""Build the real EnrollKeys request for the P256 device key.

This replaces the empty stub. It generates the device key, encodes its public
key the way Chrome's SecureMessageDelegate does, and signs the proof-of-
possession the CryptAuth v2 enrollment protocol asks for.

From Chromium:
  - cryptauth_v2_enroller_impl.cc  — builds EnrollSingleKeyRequest
  - cryptauth_key_proof_computer_impl.cc — key proof = ECDSA-SHA256 over
    (salt + session_id), signed by the new key
  - cryptauth_enrollment_constants.cc — the salt and key names

For a P256 (asymmetric) key, no server Diffie-Hellman is needed; that is only
for symmetric keys. That is why syncKeys returned no server_ephemeral_dh.

The one encoding to watch is key_material. Chrome sends a securemessage
GenericPublicKey proto (EC_P256 with x,y), not raw DER. If the server rejects
key_material, this is the function to revisit.
"""
import base64

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import Prehashed  # noqa: F401
from cryptography.hazmat.primitives import hashes

import pb

# cryptauth_enrollment_constants.cc
KEY_NAME = "PublicKey"
KEY_HANDLE = b"device_key"  # kCryptAuthFixedUserKeyPairHandle
KEY_PROOF_SALT = b"CryptAuth Key Proof"

# securemessage GenericPublicKey.PublicKeyType
PUBLIC_KEY_TYPE_EC_P256 = 1


def _java_bigint_bytes(value: int) -> bytes:
    """Big-endian two's complement, like Java BigInteger.toByteArray().

    securemessage encodes EC coordinates this way: a positive number whose top
    bit is set gets a leading 0x00, so it stays positive.
    """
    length = (value.bit_length() // 8) + 1
    return value.to_bytes(length, "big")


def _generic_public_key(pub: ec.EllipticCurvePublicKey) -> bytes:
    nums = pub.public_numbers()
    x = _java_bigint_bytes(nums.x)
    y = _java_bigint_bytes(nums.y)
    ec_p256 = pb.bytes_(1, x) + pb.bytes_(2, y)
    return pb.varint(1, PUBLIC_KEY_TYPE_EC_P256) + pb.message(2, ec_p256)


def build_enroll_single_key_request(random_session_id_b64: str) -> dict:
    """Return the JSON EnrollSingleKeyRequest for the device key.

    random_session_id_b64 is the string syncKeys returned (base64 of the
    session bytes). The proof is signed over the raw session bytes.
    """
    session_bytes = base64.b64decode(random_session_id_b64)

    priv = ec.generate_private_key(ec.SECP256R1())
    pub = priv.public_key()

    key_material = _generic_public_key(pub)

    # Key proof: ECDSA-SHA256 over salt + session bytes (DER signature).
    key_proof = priv.sign(KEY_PROOF_SALT + session_bytes, ec.ECDSA(hashes.SHA256()))

    def b64(b: bytes) -> str:
        return base64.b64encode(b).decode("ascii")

    return {
        "keyName": KEY_NAME,
        "newKeyHandle": b64(KEY_HANDLE),
        "keyMaterial": b64(key_material),
        "keyProof": b64(key_proof),
    }
