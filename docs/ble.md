# The BLE phase: connecting the Mac to the phone

Server-side enrollment (see the other docs) registered the Mac in the account's
Better Together group. Everything from here is **on-device**: the Mac and phone
find each other over Bluetooth LE and open an encrypted channel, then exchange
each feature's messages. None of it needs Google's servers — but it does need a
phone signed into the same account to talk to.

Mapped from `chromeos/ash/services/secure_channel`.

## The connection flow

1. **Discovery (EIDs).** Each device advertises a 2-byte ephemeral ID that
   rotates every 15 minutes, derived from "beacon seeds" shared in the DeviceSync
   metadata. The Mac computes the phone's expected EIDs from the phone's seeds
   and scans for a match (and advertises its own). No stable, trackable id is
   ever broadcast.
2. **BLE connection + weave.** Connect GATT; messages are packetized over a
   characteristic using the "uWeave" framing (handshake, then data packets).
3. **Authentication.** A device-to-device handshake over securemessage using the
   enrolled BetterTogether keys plus fresh ephemeral keys, producing session keys
   for an AES-256-GCM encrypted channel (the "SecureContext").
4. **Features.** Over that channel, each feature has its own messages: Phone Hub
   (status, notifications), Instant Tethering, Smart Lock, etc.

## What splits offline vs. on-device

**Offline, pure crypto/logic — buildable and testable now (Python):**
- ✅ **EID discovery** (`probe/ble/eid.py`) — the rotating-ID derivation and
  matching. Done, unit-tested against the Chromium algorithm.
- ⬜ **uWeave framing** — packetization. Pure byte-format work.
- ⬜ **Device-to-device authenticator** — the handshake. Reuses
  `securemessage.py`; testable with a local initiator+responder round-trip.
- ⬜ **Beacon seeds in metadata** — generate seeds and include them in the
  DeviceSync `BetterTogetherDeviceMetadata` (currently left empty).

**On-device — needs Swift/CoreBluetooth and a live phone:**
- ⬜ The BLE radio: advertising, scanning, GATT connect. macOS does this through
  CoreBluetooth, so this layer is Swift, not Python.
- ⬜ End-to-end testing against a real phone on the same account.

## The gating fact

A phone must be **signed into the same account** for any of this to connect. The
throwaway account has no phone, so the radio and the features can be *written*
but not *proven* until a phone is on the account (add the throwaway to a test
phone, or use the real account).

## Status

EID discovery done. The next offline pieces are the authenticator and uWeave
framing (both reusable as a reference/oracle for the eventual Swift radio code).
