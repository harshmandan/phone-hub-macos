# phone-hub-macos

Make a Mac use an Android phone's **built-in** cross-device features — the ones a
Chromebook gets: one-tap hotspot (Instant Tethering), unlock with the phone
(Smart Lock), recent photos (Phone Hub camera roll) — with **no app on the
phone**. The phone already ships this; only the desktop side is missing.

This works by having the Mac enroll with Google as a Chrome device, the same way
a Chromebook does, then connecting to the phone over Bluetooth LE.

> Research project. Uses a throwaway Google account. It talks to a private Google
> service (CryptAuth) the way [microG](https://github.com/microg/GmsCore) does.

## Status

| Gate | What it proves | Result |
| --- | --- | --- |
| 1. Scope | the account can get the `cryptauth` OAuth scope | **passed** |
| 2. Enroll | Google accepts the Mac as `device_type = CHROME` | **passed** |
| 3. Enrolled | the device key is accepted (enrollKeys 200) | **passed** (server side) |
| 4. Registered | the Mac is in the Better Together registry (DeviceSync 200) | **passed** (as "Google eve") |

Gates 1 and 2 were the real unknowns. Both cleared with HTTP 200s. What remains
is ordinary engineering, documented in Chromium's source, not guesswork.

See [docs/protocol-and-test.md](docs/protocol-and-test.md) for the exact calls
and results, and [docs/overview.md](docs/overview.md) for why this path and not
Apple Continuity or KDE Connect.

## Layout

- `probe/` — Python feasibility probe. Proves the server accepts the Mac. Not the
  real client.
- `docs/` — findings and protocol notes.

## Roadmap

1. **Full `enrollKeys`** — P256 device key, ECDH, signed enrollment. After this
   the phone lists the Mac (gate 3). ← next
2. **Real GCM registration** — Android/GMS check-in + InstanceID, so device-sync
   pushes arrive.
3. **BLE secure channel** — UKEY2 handshake to the phone.
4. **Features** — Instant Tethering, Smart Lock, Phone Hub, one at a time.
5. **Native client** — reimplement in Swift, to ship inside
   [Tether](https://github.com/subhashhhhhh/Tether) or on its own.

## Credit

Protocol details read from microG (`GmsCore`) and the Chromium ChromeOS source
(`chromeos/ash/services/device_sync`, `chrome/browser/ash/cryptauth`).
