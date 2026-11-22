# Plan: the native Swift client

The Python probe proved the protocol end to end on the server side and built the
offline BLE crypto. This is the plan to turn that into a real macOS client.

## Shape: a framework, not a Tether plugin

Build **PhoneHubKit**, a standalone Swift package. Tether (or a small standalone
app) consumes it.

Why not a Tether plugin: Tether's `TetherPlugin` model is KDE Connect — JSON
packets over a local TLS socket, devices trusted by pinned certificate. Phone
Hub is a different world: a Google account, CryptAuth enrollment, BLE transport,
CryptAuth/securegcm crypto. Forcing it into the plugin protocol would tangle two
unrelated trust and transport models. A separate framework keeps Tether's code
clean; Tether just shows the Phone Hub device alongside its KDE Connect ones.

## Layer map (proven Python → Swift)

| Layer | Python (done) | Swift |
| --- | --- | --- |
| Account auth | gpsoauth flow | URLSession; port the device-auth calls |
| Enrollment / DeviceSync | `probe/*.py` | URLSession + SwiftProtobuf |
| SecureMessage | `securemessage.py` | CryptoKit + CommonCrypto |
| EID discovery | `ble/eid.py` | CryptoKit (SHA256) |
| uWeave framing | `ble/weave.py` | plain `Data` |
| Session keys / channel | `ble/session_keys.py`, `secure_context.py` | CryptoKit |
| BLE radio | — (Python can't) | CoreBluetooth |
| Pairing | — (needs phone) | CoreBluetooth + reverse-engineering |
| Features | — | per-feature message handlers |

## Crypto mapping

- **P256 keygen / ECDH / ECDSA**: CryptoKit `P256.KeyAgreement`, `P256.Signing`.
- **SHA256, HMAC, HKDF**: CryptoKit `SHA256`, `HMAC`, `HKDF`.
- **AES-256-CBC**: *not in CryptoKit* — use CommonCrypto (`CCCrypt`). securemessage
  is CBC + HMAC, not GCM, so this is required.
- **Protobuf**: SwiftProtobuf, generated from the `.proto` files already
  identified (cryptauth v2, securegcm, securemessage, better_together metadata).

The tested Python modules are the **reference oracle**: port each with its unit
test ported too, and check Swift output byte-for-byte against the Python.

## BLE radio (CoreBluetooth)

The Mac is the **initiator** = BLE **central**: scan for the phone's advertised
EID in the service data, connect as GATT client, talk uWeave over the TX/RX
characteristics. macOS supports the central role fully, so this is feasible.

- Extract the uWeave GATT service + characteristic UUIDs from
  `ble_weave_client_connection.cc`.
- Scan filtering: match advertisement service data against `eid.py`'s computed
  EIDs for the phone's beacon seeds.
- Caveat: macOS CoreBluetooth restricts *advertising* custom service data
  (peripheral role). Since the Mac is the central here, that mostly does not
  bite — but confirm whether any flow needs the Mac to advertise.

## Pairing — the real unknown

The Chromebook setup (see the reference screenshots) detects the phone, asks for
the account **PIN** and a **phone-side permission**, then "All set." That is a
multidevice **setup/pairing** step, separate from the server enrollment we did,
and it is where the handshake's persistent symmetric key is established.
Reproducing it needs a phone and reverse-engineering `multidevice_setup` /
`CryptAuthV2Enrollment` setup flows. **This is the gating task** for everything
on-device.

## Milestones

1. **Port the crypto** (offline). securemessage, EID, weave, session keys,
   channel → Swift, each with its Python test ported. Fully verifiable without a
   phone.
2. **Enrollment + DeviceSync in Swift** (testable against the server with the
   throwaway account). Reuses the known requests.
3. **CoreBluetooth scan/connect** (needs phone). Find and GATT-connect the phone.
4. **Pairing** (needs phone). Reproduce the setup/PIN flow.
5. **Handshake + secure channel end-to-end** (needs phone). First encrypted
   message exchanged.
6. **Features**, one at a time: Phone Hub status (battery/signal/ring) first —
   smallest protocol — then notifications, then Instant Tethering, then Smart
   Lock.

Steps 1–2 can proceed now. Steps 3+ need a phone on the account.

## Integration with Tether

PhoneHubKit as a Swift-package dependency. Tether surfaces a Phone Hub device in
its sidebar; features map to UI (notifications into the existing notifications
pane; hotspot/unlock as new controls). Keep PhoneHubKit free of Tether types so
it can also ship as a standalone app.

## Risks

- **Pairing is unmapped** — the one true unknown; it may need meaningful
  reverse-engineering with a phone.
- **macOS BLE advertising limits** — mitigated by the Mac being central, but
  confirm.
- **Account-linked fragility** — Play Services / Chrome updates can shift the
  protocol; the client is unofficial.
- **Distribution** — Tether ships as an unsigned DMG; BLE + a background agent
  are fine there, but note entitlements if it is ever sandboxed/notarized.
