"""Minimal protobuf wire encoder.

Only what the CryptAuth probe needs: no .proto files, no protoc. The CryptAuth
messages are flat enough to encode by hand, which avoids a compile toolchain the
test would otherwise depend on.
"""


def _varint(n: int) -> bytes:
    if n < 0:
        n += 1 << 64  # two's complement for negative int64
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _tag(field: int, wire: int) -> bytes:
    return _varint((field << 3) | wire)


def varint(field: int, value: int) -> bytes:
    return _tag(field, 0) + _varint(value)


def boolean(field: int, value: bool) -> bytes:
    return varint(field, 1 if value else 0)


def string(field: int, value: str) -> bytes:
    return bytes_(field, value.encode("utf-8"))


def bytes_(field: int, value: bytes) -> bytes:
    return _tag(field, 2) + _varint(len(value)) + value


def message(field: int, value: bytes) -> bytes:
    return bytes_(field, value)


def fixed64(field: int, value: int) -> bytes:
    return _tag(field, 1) + value.to_bytes(8, "little")


def packed_varints(field: int, values) -> bytes:
    body = b"".join(_varint(v) for v in values)
    return _tag(field, 2) + _varint(len(body)) + body
