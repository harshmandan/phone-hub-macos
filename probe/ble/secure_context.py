"""The device-to-device encrypted channel, after authentication.

Each message is a symmetric SecureMessage (AES-256-CBC + HMAC-SHA256) wrapping a
DeviceToDeviceMessage{message, sequence_number}, with a GcmMetadata in the
public header. Sequence numbers start at 1 (the auth messages) and increment.

From chromeos/ash/services/secure_channel/device_to_device_secure_context.cc.

This module is in the probe (Python) so the channel crypto can be exercised and
verified offline. The live radio and handshake run in the Swift layer.
"""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import pb  # noqa: E402
import securemessage as sm  # noqa: E402

GCM_METADATA_VERSION = 1
# securegcm.Type.DEVICE_TO_DEVICE_MESSAGE
TYPE_DEVICE_TO_DEVICE_MESSAGE = 13

# Sequence numbers 1 are the authentication messages (ResponderAuth / InitiatorAuth).
AUTH_SEQUENCE_NUMBER = 1


class SecureContext:
    def __init__(self, session_keys, role: str):
        if role == "initiator":
            self._encode_key = session_keys.initiator
            self._decode_key = session_keys.responder
        elif role == "responder":
            self._encode_key = session_keys.responder
            self._decode_key = session_keys.initiator
        else:
            raise ValueError("role must be initiator or responder")
        self._encode_seq = AUTH_SEQUENCE_NUMBER
        self._decode_seq = AUTH_SEQUENCE_NUMBER

    def encode(self, message: bytes) -> bytes:
        self._encode_seq += 1
        d2d = pb.bytes_(1, message) + pb.varint(2, self._encode_seq)
        gcm = pb.varint(1, TYPE_DEVICE_TO_DEVICE_MESSAGE) + pb.varint(2, GCM_METADATA_VERSION)
        return sm.create(self._encode_key, d2d, public_metadata=gcm)

    def decode(self, blob: bytes) -> bytes:
        payload, _ = sm.unwrap(self._decode_key, blob)
        fields = sm._read_fields(payload)
        seq = fields.get(2)
        self._decode_seq += 1
        if seq != self._decode_seq:
            raise ValueError(f"expected sequence {self._decode_seq}, got {seq}")
        return fields[1]
