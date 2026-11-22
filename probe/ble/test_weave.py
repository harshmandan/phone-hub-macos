"""Offline tests for uWeave packet framing. Run: python3 test_weave.py"""
import os

from weave import (PacketGenerator, PacketReceiver, CONTROL,
                   CONNECTION_REQUEST, CONNECTION_RESPONSE, DEFAULT_MAX_PACKET_SIZE)


def test_connection_request_format():
    g = PacketGenerator()
    req = g.connection_request()
    assert len(req) == 7
    assert (req[0] >> 7) & 1 == CONTROL
    assert req[0] & 0x0F == CONNECTION_REQUEST
    assert req[1:3] == b"\x00\x01"  # version min, big-endian


def test_fragmentation_round_trip():
    for size in (1, 18, 19, 20, 100, 1000):
        g = PacketGenerator(max_packet_size=DEFAULT_MAX_PACKET_SIZE)
        r = PacketReceiver()
        assert r.receive(g.connection_request()) == ("control", CONNECTION_REQUEST)
        msg = os.urandom(size)
        packets = g.encode_data_message(msg)
        # every packet fits the MTU
        for p in packets:
            assert len(p) <= DEFAULT_MAX_PACKET_SIZE
        out = None
        for p in packets:
            out = r.receive(p)
        assert out == msg, f"size {size}: mismatch"


def test_counter_sequence_enforced():
    g = PacketGenerator()
    r = PacketReceiver()
    r.receive(g.connection_request())
    packets = g.encode_data_message(os.urandom(200))
    # dropping a packet breaks the counter
    r.receive(packets[0])
    try:
        r.receive(packets[2]); assert False
    except ValueError:
        pass


def test_counter_wraps_mod_8():
    g = PacketGenerator()
    r = PacketReceiver()
    r.receive(g.connection_request())
    # a long message spanning >8 packets exercises the mod-8 wrap
    msg = os.urandom(19 * 12)
    out = None
    for p in g.encode_data_message(msg):
        out = r.receive(p)
    assert out == msg


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
    print("all passed")
