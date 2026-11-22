"""BLE ephemeral IDs (EIDs) for Better Together device discovery.

How a device finds another over BLE without a stable, trackable identifier: each
device advertises a 2-byte EID that rotates every 15 minutes, derived from
"beacon seeds" it shares (inside its encrypted DeviceSync metadata). To find a
phone, the Mac computes the phone's expected EIDs from the phone's seeds and
scans for a matching advertisement.

Ported from chromeos/ash/services/secure_channel:
  raw_eid_generator_impl.cc  — the hash
  background_eid_generator.cc — periods, look-ahead, seed selection

This is pure crypto/logic, testable offline. The actual BLE radio (advertising,
scanning) is separate and lives in the Swift/CoreBluetooth layer.
"""
import hashlib
import struct
import time
from dataclasses import dataclass

EID_PERIOD_MS = 15 * 60 * 1000  # rotates every 15 minutes
EID_LOOKAHEAD = 2  # also compute the 2 periods before/after now
EID_BYTES = 2


@dataclass
class BeaconSeed:
    data: bytes
    start_time_ms: int
    end_time_ms: int


def raw_eid(seed_data: bytes, start_of_period_ms: int,
            extra_entropy: bytes | None = None) -> bytes:
    """SHA256(seed || [extra_entropy] || bigendian64(period_start))[:2]."""
    to_hash = seed_data
    if extra_entropy:
        to_hash += extra_entropy
    to_hash += struct.pack(">q", start_of_period_ms)  # base::U64ToBigEndian
    return hashlib.sha256(to_hash).digest()[:EID_BYTES]


def _seed_for(ts_ms: int, seeds: list[BeaconSeed]) -> BeaconSeed | None:
    for s in seeds:
        if s.start_time_ms <= ts_ms <= s.end_time_ms:
            return s
    return None


def eid_for(ts_ms: int, seeds: list[BeaconSeed]) -> tuple[bytes, int] | None:
    """The EID and its period-start for a timestamp, or None if uncovered."""
    seed = _seed_for(ts_ms, seeds)
    if not seed:
        return None
    offset = ts_ms - seed.start_time_ms
    start_of_period = seed.start_time_ms + (offset // EID_PERIOD_MS) * EID_PERIOD_MS
    return raw_eid(seed.data, start_of_period), start_of_period


def nearest_eids(seeds: list[BeaconSeed], now_ms: int | None = None) -> list[tuple[bytes, int]]:
    """EIDs for now and the look-ahead/behind periods (to advertise or scan)."""
    now = now_ms if now_ms is not None else int(time.time() * 1000)
    out = []
    for i in range(-EID_LOOKAHEAD, EID_LOOKAHEAD + 1):
        r = eid_for(now + i * EID_PERIOD_MS, seeds)
        if r:
            out.append(r)
    return out


def matches(advertisement_service_data: bytes, remote_seeds: list[BeaconSeed],
            now_ms: int | None = None) -> bool:
    """True if a scanned advertisement's EID came from these remote seeds."""
    eid = advertisement_service_data[:EID_BYTES]
    return any(eid == e for e, _ in nearest_eids(remote_seeds, now_ms))


def generate_beacon_seeds(now_ms: int | None = None, num: int = 2,
                          window_days: int = 7) -> list[BeaconSeed]:
    """Create our own beacon seeds (random data over consecutive windows).

    A real build publishes these inside the device's DeviceSync metadata so the
    phone can derive our EIDs. 64-byte seeds, matching CryptAuth.
    """
    import os

    now = now_ms if now_ms is not None else int(time.time() * 1000)
    window = window_days * 24 * 60 * 60 * 1000
    start = now - window  # cover a bit of the past for clock skew
    seeds = []
    for _ in range(num):
        seeds.append(BeaconSeed(os.urandom(64), start, start + window))
        start += window
    return seeds
