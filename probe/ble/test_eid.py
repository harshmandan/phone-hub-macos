"""Offline tests for the EID discovery crypto. Run: python3 test_eid.py"""
import hashlib
import struct

import eid


def test_formula_matches_source():
    ts = 1795000000000 // eid.EID_PERIOD_MS * eid.EID_PERIOD_MS
    expect = hashlib.sha256(b"eidSeed" + struct.pack(">q", ts)).digest()[:2]
    assert eid.raw_eid(b"eidSeed", ts) == expect
    assert len(expect) == eid.EID_BYTES


def test_sensitivity():  # mirrors raw_eid_generator_impl_unittest.cc
    ts = 1795000000000
    assert eid.raw_eid(b"eidSeed", ts) == eid.raw_eid(b"eidSeed", ts)
    assert eid.raw_eid(b"eidSeed1", ts) != eid.raw_eid(b"eidSeed2", ts)
    assert eid.raw_eid(b"eidSeed", ts) != eid.raw_eid(b"eidSeed", ts + 1)
    assert eid.raw_eid(b"eidSeed", ts) != eid.raw_eid(b"eidSeed", ts, b"x")


def test_discovery_round_trip():
    now = 1795000000000
    phone = eid.generate_beacon_seeds(now_ms=now)
    adv, _ = eid.eid_for(now, phone)
    assert eid.matches(adv + b"\x00flags", phone, now_ms=now)
    assert not eid.matches(adv + b"\x00", eid.generate_beacon_seeds(now_ms=now), now_ms=now)


def test_lookahead():
    now = 1795000000000
    seeds = eid.generate_beacon_seeds(now_ms=now)
    near = eid.nearest_eids(seeds, now_ms=now)
    assert len(near) == 2 * eid.EID_LOOKAHEAD + 1
    for _, p in near:
        assert (p - seeds[0].start_time_ms) % eid.EID_PERIOD_MS == 0


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
    print("all passed")
