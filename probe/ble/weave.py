"""uWeave: chunking messages into BLE-sized packets.

A BLE characteristic write is small (~20 bytes by default), so a secure-channel
message is split across several "weave" packets and reassembled. Each packet has
a 1-byte header:

    bit 7     : type (0 = data, 1 = control)
    bits 6-4  : packet counter (mod 8, must arrive in order)
    bit 3     : first data packet
    bit 2     : last data packet
    bits 3-0  : control command (control packets only)

Control commands: CONNECTION_REQUEST(0), CONNECTION_RESPONSE(1), CLOSE(2).
Short fields are big-endian uint16.

From chromeos/ash/services/secure_channel/ble_weave_packet_{generator,receiver}.cc
and ble_weave_defines.h. Pure byte-format logic, testable offline; the actual
characteristic reads/writes are the Swift/CoreBluetooth layer.
"""
import struct

DATA = 0
CONTROL = 1
CONNECTION_REQUEST = 0
CONNECTION_RESPONSE = 1
CONNECTION_CLOSE = 2

DEFAULT_MAX_PACKET_SIZE = 20
WEAVE_VERSION = 1
SELECT_MAX_PACKET_SIZE = 0
MAX_PACKET_COUNTER = 8


def _short(val: int) -> bytes:
    return struct.pack(">H", val)


class PacketGenerator:
    def __init__(self, max_packet_size: int = DEFAULT_MAX_PACKET_SIZE):
        self.max_packet_size = max_packet_size
        self._next_counter = 0

    def _counter_bits(self) -> int:
        c = self._next_counter % MAX_PACKET_COUNTER
        self._next_counter += 1
        return c << 4

    def connection_request(self) -> bytes:
        header = (CONTROL << 7) | CONNECTION_REQUEST  # counter 0
        self._next_counter = 1
        return bytes([header]) + _short(WEAVE_VERSION) + _short(WEAVE_VERSION) + _short(SELECT_MAX_PACKET_SIZE)

    def connection_response(self) -> bytes:
        header = (CONTROL << 7) | CONNECTION_RESPONSE  # counter 0
        self._next_counter = 1
        return bytes([header]) + _short(WEAVE_VERSION) + _short(self.max_packet_size)

    def connection_close(self, reason: int = 0) -> bytes:
        header = (CONTROL << 7) | self._counter_bits() | CONNECTION_CLOSE
        return bytes([header]) + _short(reason)

    def encode_data_message(self, message: bytes) -> list[bytes]:
        assert message
        payload_size = self.max_packet_size - 1
        n = (len(message) + payload_size - 1) // payload_size
        packets = []
        for i in range(n):
            chunk = message[i * payload_size:(i + 1) * payload_size]
            header = (DATA << 7) | self._counter_bits()
            if i == 0:
                header |= 1 << 3  # first
            if i == n - 1:
                header |= 1 << 2  # last
            packets.append(bytes([header]) + chunk)
        return packets


class PacketReceiver:
    def __init__(self):
        self._next_counter = 0
        self._buffer = bytearray()
        self._receiving = False

    @staticmethod
    def packet_type(p: bytes) -> int:
        return (p[0] >> 7) & 1

    @staticmethod
    def control_command(p: bytes) -> int:
        return p[0] & 0x0F

    @staticmethod
    def is_first(p: bytes) -> bool:
        return bool((p[0] >> 3) & 1)

    @staticmethod
    def is_last(p: bytes) -> bool:
        return bool((p[0] >> 2) & 1)

    def _check_counter(self, p: bytes) -> None:
        count = (p[0] >> 4) & 7
        if count != self._next_counter % MAX_PACKET_COUNTER:
            raise ValueError(f"packet out of sequence: {count}")
        self._next_counter += 1

    def receive(self, p: bytes):
        """Feed one packet. Returns ("control", command) for control packets,
        None while a data message is still arriving, or the reassembled bytes
        when the last data packet completes a message."""
        self._check_counter(p)
        if self.packet_type(p) == CONTROL:
            return ("control", self.control_command(p))
        # data
        if self.is_first(p) != (not self._receiving):
            raise ValueError("unexpected first-packet flag")
        if self.is_first(p):
            self._buffer = bytearray()
            self._receiving = True
        self._buffer += p[1:]
        if self.is_last(p):
            self._receiving = False
            return bytes(self._buffer)
        return None
