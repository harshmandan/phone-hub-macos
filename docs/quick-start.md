# The QR "Quick Start" setup flow

The user's help page: on the Chromebook, "Quick setup with your Android phone"
shows a QR; the phone scans it to confirm. This is Chromium's **Quick Start**
(`chrome/browser/ash/login/oobe_quick_start/`), and it is a different, larger
mechanism than the BLE Better Together link we were stuck on.

## How it works (from source)

1. The Chromebook makes a random **advertising_id** (10 bytes) and a **shared
   secret** (32 bytes). — `connectivity/advertising_id.cc`, `qr_code.cc`
2. The QR is a URL: `https://signin.google/qs/<advertising_id>?key=<base64url
   shared_secret>`. — `qr_code.cc` GetQRCodeURLString
3. The Chromebook advertises over **Nearby Connections**
   (`NearbyConnectionsManager`), endpoint info carrying the advertising_id; it
   also puts up a Fast Pair beacon (service `0xFE2C`, Chromebook model id
   `0x306846`). — `target_device_connection_broker_impl.cc`, `fast_pair_advertiser.cc`
4. The phone scans the QR → has the id + secret → finds the Chromebook via
   Nearby Connections → connects.
5. **Handshake:** AES-256-GCM keyed by the shared secret, with a nonce and a
   `role` in an AuthenticationPayload — both sides prove they know the secret.
   — `handshake_helpers.cc`
6. `second_device_auth_broker` then transfers the Google account to the device.

## What this means for the project

- **Not a CoreBluetooth wall.** The transport is Nearby Connections, and a Mac
  *can* do Nearby Connections — NearDrop and rquickshare already implement it on
  macOS for Quick Share. So unlike raw BLE advertising, this isn't platform-
  blocked.
- **But it is a large build.** Reimplementing Nearby Connections + the Quick
  Start handshake + the auth broker is a much bigger undertaking than all the
  CryptAuth work here — effectively a new sub-project, best bootstrapped from the
  open-source Quick Share clients (NearDrop, rquickshare) which already have the
  Nearby Connections + UKEY2 machinery on macOS.
- **Different outcome.** This is **OOBE Quick Start — new-Chromebook onboarding**.
  It transfers the Google *account* to the Mac-as-Chromebook. That is arguably
  bigger than Phone Hub, but it is a different thing; whether it then unlocks
  Phone Hub is a further unknown.

## Build progress

- ✅ QR + handshake crypto in Swift (`QuickStart.swift`): advertising id (10B) +
  shared secret (32B) → the signin.google URL; and BuildHandshakeMessage /
  VerifyHandshakeMessage (AES-256-GCM over AuthenticationPayload{role,
  auth_string}, roles target=1 / source=2). Round-trip unit-tested.
- ✅ `qr` command renders a scannable QR PNG (CoreImage) — to test whether a
  real phone recognises our Quick Start QR format.
- ✅ **UKEY2 handshake** (`Ukey2.swift`) — the security core of Nearby
  Connections. P256 ECDH → SHA256 → HKDF with salts "UKEY2 v1 next" / "UKEY2 v1
  auth" over the two init messages (ported from google/ukey2). Both sides derive
  the same next-secret + auth string; round-trip unit-tested. Reuses our
  SecureMessage ECDH + GenericPublicKey.
- ✅ **Nearby OfflineFrames** (`NearbyFrames.swift`) — the connection protocol:
  ConnectionRequest / ConnectionResponse / KeepAlive / PayloadTransfer frames +
  the 4-byte length prefix. Build/parse round-trip tested, and a payload frame
  rides correctly over the UKEY2→SessionKeys→SecureContext channel (the layers
  interlock).
- ⬜ **The medium / live transport** — the remaining bulk, and it needs real
  networking + a phone, so it runs in a Terminal, not here:
  - discovery: advertise the endpoint (advertising_id) over BLE, and an mDNS
    (`_FC9F5ED42C8A.*._tcp`-style) service for Wi-Fi LAN;
  - a TCP socket carrying the length-prefixed frames;
  - orchestration: sequence ConnectionRequest ↔ UKEY2 ↔ ConnectionResponse, then
    payloads, matching Nearby Connections' state machine.
  Best adapted from NearDrop (Swift/macOS) — it already does exactly this medium
  layer on a Mac.
- ⬜ second-device auth / account transfer.

Everything through the OfflineFrames is built and unit-tested offline (7 green
checks). The remaining work is live networking + the phone.

Done so far ties together: UKEY2 yields the `auth_string`, which the Quick Start
AES-GCM handshake (already built) consumes. The gap is the transport that carries
these messages.

## Medium verified against a real phone (milestone)

Running the `serve` advertiser, the **phone discovered the Mac in Quick Share**.
This proves the whole macOS Nearby Connections medium is correct end to end:
Bonjour service name (`[0x23, endpointId×4, serviceIdHash×3, 0,0]` base64url),
`_FC9F5ED42C8A._tcp.`, the `n=` TXT endpoint_info ([deviceType<<1][16 rand][name
len][name]), and the TCP listener. The "can macOS do this at all" question is
answered: yes.

Remaining to reach Quick Start: swap the Quick Share service id for the Quick
Start one (different service type + hash — extract from Chromium's
target_device_connection_broker), and the connection orchestration
(ConnectionRequest ↔ UKEY2 ↔ ConnectionResponse ↔ Quick Start AES-GCM handshake
↔ payloads), all of which reuse the pieces already built and tested here.

## Live bidirectional connection (breakthrough)

With `serve` running, the phone connected over TCP (192.168.1.22) and sent its
first frame: **273 bytes, type 1 = ConnectionRequest**, which our OfflineFrame
parser identified correctly. So the full medium stack is proven with real phone
traffic: Bonjour discovery → TCP connect → 4-byte length-prefix read → Nearby
OfflineFrame parse.

All the protocol pieces exist and are tested (UKEY2, frames, secure channel,
Quick Start handshake). What remains is the **orchestration** — the connection
state machine: receive ConnectionRequest → exchange ConnectionRequest/UKEY2
(ClientInit/ServerInit/ClientFinished) → ConnectionResponse(accept) → the
encrypted channel → payloads → the Quick Start AES-GCM handshake → second-device
auth. This is now live-testable against the phone.

## FULL STACK VERIFIED LIVE (the milestone)

Running `serve`, the phone drove the whole inbound handshake and our state
machine completed it:

```
frame 275B, type 1                     ConnectionRequest
UKEY2: got ClientInit, sent ServerInit
UKEY2 complete — D2D channel derived (auth 82bf7e3f…)
got phone ConnectionResponse; sending accept
sent ConnectionResponse(accept) + an encrypted keep-alive
🔓 decrypted a frame — D2D CHANNEL WORKS LIVE
```

So the ENTIRE Nearby Connections transport + security stack is proven against a
real phone: Bonjour discovery → TCP → length-prefixed framing → UKEY2 key
exchange (shared secret derived) → the D2D AES-256-CBC+HMAC channel (we decrypted
a frame the phone encrypted, so our keys match). The reusable pieces
(Ukey2, SecureContext/SessionKeys with "client"/"server", NearbyFrames) are all
confirmed correct on the wire.

The phone's transfer then "failed" only because we drove it via Quick SHARE and
did not continue Quick Share's app protocol (we sent a keep-alive). That is fine
— Quick Share was just the test driver.

## What remains for Quick Start (over this proven channel)

1. Advertise with the Quick START Nearby service id (not Quick Share's) so the
   phone's Quick Start flow discovers us.
2. Speak the Quick Start app protocol over the channel: the AES-GCM handshake
   (already built, keyed by the QR secret + the UKEY2 auth string) and the
   quick-start messages, then second_device_auth.

The transport and crypto — the hard part — are done and live-verified.

## Quick Start-specific values (from current Chromium main)

- **Nearby service id**: `com.google.android.gms.smartdevice.NC_ID`
  (quick_start_connectivity_service_impl.cc).
- **mDNS service type**: `_2D103F062BB8._tcp.`, endpoint hash `2D 10 3F` —
  derived as `_` + SHA256(service_id)[:6], a rule verified because
  SHA256("NearbySharing")[:6] = `FC9F5ED42C8A`, the known Quick Share type.
- **Quick Start endpoint_info** (target_device_connection_broker_impl.cc):
  `[version=1][display name ≤18, null-padded][base64url(advertisement_data[60])]`,
  where advertisement_data = `[verificationStyle=5 OUT_OF_BAND][deviceType=8]`
  `[advertisingId string][isQuickStart=1][preferTargetUserVerification=0]` zero-
  padded to 60. verificationStyle 5 = OUT_OF_BAND tells the phone to scan the QR.

Implemented: `NearbyAdvertiser.quickStart(name:advertisingId:)` + the `qsserve`
command (advertises as Quick Start and prints the matching QR).

## Up-to-date references (NearDrop is older)

- **google/nearby** — the canonical Nearby Connections, actively maintained
  (pushed 2026-11-21). Authoritative for the wire protocol.
- **Martichou/rquickshare** — Rust Quick Share for Linux + macOS (2026-05),
  more current than NearDrop.
- **Chromium main** `chrome/browser/ash/login/oobe_quick_start` — authoritative
  for the Quick Start specifics above.

Note: NearDrop's protocol details were nonetheless correct — our live handshake
completed using them, so the transport has not drifted. These newer sources are
for going further (Quick Start app protocol, current edge cases).

## The definitive wall (conclusion)

Advertising as a real Quick Start target (`_2D103F062BB8._tcp.`) with the matching
QR, the phone never connected — and the owner confirmed: **there is no phone-side
way to initiate or scan a Chromebook link.** No notification, no setup prompt, no
QR-scan entry. Both Phone Hub (Better Together) and Quick Start are
**Chromebook-initiated**; the phone only responds when a genuine Chromebook
reaches it during that Chromebook's setup flow.

So the simulated-Mac approach reaches its ceiling here — not from a protocol gap
(every layer works), but from the phone's initiation model. Driving the link
needs the ChromeOS-side setup UI/OOBE that a non-ChromeOS device can't present.

### What was proven (all live, against a real phone)

- Server side: enroll the Mac as a CHROME device, DeviceSync, join the account's
  Better Together group, set the host flag — all 200s.
- Nearby Connections transport: discovery (Bonjour), TCP, length-prefixed framing.
- UKEY2 key exchange completed with the phone; the shared secret derived.
- The D2D AES-256-CBC+HMAC channel: we decrypted a frame the phone encrypted.

Everything up to and including a live encrypted channel with the phone works.
The one thing that doesn't is making the phone *start* the Phone Hub / Quick Start
link, because that is the Chromebook's job and the phone exposes no entry for it.

## "What is a real Chromebook" — the wall, re-examined from Chrome source

Read `chrome/browser/ash/login/oobe_quick_start/` + `chromeos/ash/services/device_sync/`
in Chromium main. "Real Chromebook" splits into three separable identities:

1. **To CryptAuth (server enrollment):** `device_type=CHROME` + metadata. Software only.
   `cryptauth_v2_enroller_impl.cc` proves identity by a key-proof (ECDSA over the
   server's random_session_id) — no TPM, no attestation. We fake it; server accepts. ✅

2. **To the phone (Phone Hub / Better Together setup):** software key-proofs + an auth
   token (`multidevice_setup.mojom`). No hardware attestation anywhere in the OSS path.
   We ran Nearby + UKEY2 + the D2D channel live. ✅

3. **Quick Start ACCOUNT TRANSFER (OOBE only):** the one hard hardware gate.
   `second_device_auth_broker.cc` → `FetchAttestationCertificate` with
   `PROFILE_DEVICE_SETUP_CERTIFICATE` / `kDeviceSetupKey`; the TPM/Cr50-rooted cert
   (subject `O=Chrome Device Setup`) is base64'd into the Gaia `/v1/startsession`
   body and verified SERVER-SIDE by Google's Privacy CA. A Mac cannot produce it. ❌
   **But Phone Hub does not use this step** — it's only for onboarding a new Chromebook
   and copying the Google account onto it.

### The actual missing piece: the Fast Pair trigger beacon

`connectivity/fast_pair_advertiser.cc`: the phone's "Set up this Chromebook" prompt is
triggered by a **BLE Fast Pair broadcast**, NOT by the Nearby Connections advertising:
- Service UUID `0000fe2c-…` (0xFE2C Fast Pair).
- Service data = 3-byte model id; Chromebook = `{0x30,0x68,0x46}` (0x306846, confirmed).
  (Chromebase `e9316c`, Chromebox `dade43`.)
- Manufacturer data: company id `0x00e0` (Google) + the 16-byte random advertising_id.

`target_device_connection_broker_impl.cc` starts Fast Pair FIRST, then Nearby
Connections — beacon = trigger, NC = channel. We only ever broadcast the NC channel.
No same-account/server-push trigger exists in the OSS code; the trigger is purely local
BLE. (Phone-side scan/notify logic is in GMS, closed.)

### Why the Mac can't emit it, and what fixes it

Apple's CoreBluetooth advertising (`CBPeripheralManager.startAdvertising`) supports only
`CBAdvertisementDataLocalNameKey` + `CBAdvertisementDataServiceUUIDsKey`; it silently
drops service-data and manufacturer-data. So the Mac's own radio cannot put
`FE2C + 30 68 46 + Google mfr data` on air. This is an Apple API limit, not a hardware
root-of-trust wall.

Fix left to try: an external BLE board (nRF52840 / ESP32, ~$10–40) flashed to broadcast
that exact beacon, running next to the Mac while the Mac serves the NC channel + the
proven handshake. The beacon wakes the phone; the Mac answers.

### Revised conclusion

The earlier "need real ChromeOS hardware" ceiling was aimed at Quick Start account
transfer (door 3) — the one gated step, which Phone Hub never uses. For Phone Hub
itself there is NO hardware gate in open source. The single unbroken step is emitting
the FE2C/0x306846 trigger beacon, which the Mac's API blocks but a cheap external BLE
beacon can supply. Unknown (closed GMS): whether the phone will accept a non-OOBE Mac
as a Better Together host once prompted.
