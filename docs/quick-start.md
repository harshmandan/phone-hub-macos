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

## Two hardware paths to emit the FE2C/0x306846 beacon (the Mac can't, natively)

The Mac's CoreBluetooth can't broadcast custom service-data/manufacturer-data (only
local-name + service-UUID list; other adv keys are ignored). Two ways around it:

### Path A — standalone ESP32 beacon (simplest; best for the first trigger test)
A cheap USB-C ESP32 board (XIAO ESP32-C6 ~₹649, or ESP32-C3 SuperMini ~₹268) flashed
with one sketch. ESP-IDF `esp_ble_gap_config_adv_data_raw()` +
`esp_ble_gap_config_scan_rsp_data_raw()` (or NimBLE) set the exact AD structures:
FE2C service UUID + 3-byte service data {0x30,0x68,0x46} in the ADV packet,
manufacturer data (company 0x00E0 + 16-byte advertising id) in the scan response
(won't all fit one 31-byte legacy packet). Self-contained: no Mac BT stack, no libusb.
Does NOT integrate with the probe — it just beacons.

### Path B — Bumble + USB HCI dongle (Mac-side Python; the build platform)
Google's Bumble (pure-Python BLE stack) drives an external USB Bluetooth controller
with full HCI control, from the Mac, next to probe/. Confirmed workable on Apple
Silicon; friction is small and documented:
- `brew install libusb` (fallback if the bundled wheel lacks arm64)
- `sudo nvram bluetoothHostControllerSwitchBehavior="never"` (stop IOBluetooth grabbing
  the dongle; Apple TN2295), then plug the dongle in
- `usb_probe` lists the device → address it as `usb:<vid>:<pid>`

Arbitrary adv + separate scan-response is first-class (examples/run_advertiser.py):
```python
from bumble.data_types import (AdvertisingData, ServiceData16BitUUID,
    ManufacturerSpecificData, IncompleteListOf16BitServiceUUIDs)
from bumble.core import UUID
device.advertising_data = bytes(AdvertisingData([
    (AdvertisingData.INCOMPLETE_LIST_OF_16_BIT_SERVICE_CLASS_UUIDS, bytes(UUID('FE2C'))),
    # ServiceData16BitUUID(UUID('FE2C'), bytes([0x30,0x68,0x46])) via its AD tag
]))
device.scan_response_data = bytes(AdvertisingData([
    # ManufacturerSpecificData(company_identifier=0x00E0, data=<16 bytes>)
]))
await device.start_advertising(...)
```
Advantages: iterate the payload from Python instantly, script ADV vs scan-response,
and (later) the same dongle/stack can drive a real GATT connection — so Path B can grow
into more of the project, Path A can't.

Dongles (India), ranked:
1. Nordic nRF52840 USB dongle (PCA10059) + Zephyr `hci_usb` (Bumble's prebuilt
   firmware, one-time `nrfutil` flash). Bumble's own recommended controller; clean
   USB-HCI, reliable LE advertising. ~₹1,249–1,749 (Electropi / robu.in). BEST.
   NB: the Nordic *dongle*, not a XIAO nRF52840 (same SoC, but undocumented for this).
2. TP-Link UB500 (Realtek RTL8761B), ~₹499–599, no flashing — but macOS+Bumble
   unverified; watch for the BT5.3 "V2" hardware revision. Cheaper gamble.
3. CSR8510 A10, ~₹149–300 — AVOID, market flooded with broken clones (genuine =
   lsusb 0a12:0001).

### Recommended order
Path A (ESP32) first — ₹649, near-zero setup — to settle the one open question:
does the beacon make the phone show "Set up this Chromebook"? (phone-side match is
closed GMS, so this is empirical.) If it does, adopt Path B (Bumble + nRF52840 dongle)
as the platform for the actual build.

## Phone-side cold launch — the beacon trigger is bypassable (2026-11-23)

Tested on the live phone (M2101K6P, GMS). The Fast Pair beacon's only job is to push
the phone into the Quick Start **Source** flow. That flow can be opened directly, with
no beacon and no radio:

```
adb shell am start -a com.google.android.gms.smartdevice.quickstart.SOURCE_DEVICE_SETUP
```

Resolves to `com.google.android.gms/.smartdevice.quickstart.ui.SourceQuickStartActivity`,
**`exported=true`** (launchable from shell UID). It opened the real UI:
"keep both devices close until setup is complete" / "continue setup on your new device".
So the phone enters the setup flow from the phone side — the beacon is not required to
get here.

Related exported entry points (all `com.google.android.gms.smartdevice.quickstart.*`):
`SOURCE_DEVICE_SETUP`, `SOURCE_FLOW_START`, `TARGET_DEVICE_SETUP`, `HALF_SHEET_ACTIVITY`.
`LANDING_SCREEN` is `exported=false`. Gated by signature perm
`com.google.android.gms.smartdevice.permission.NOTIFY_QUICK_START_STATUS`.

### The caveat (from logcat)

```
SmartDevice: [SourceQuickStartChimeraActivity] Connection request is present: false
```

Launched cold, the activity has **no connection-request extra** — the discovered-endpoint
payload that the beacon→notification path normally hands it. So it sits on the
instructional screen ("continue setup on your new device") waiting for the **target** to
become discoverable, rather than dialing a specific endpoint. All the Nearby Connections
discovery visible in the log (`startDiscovery in nc mode`, `onEndpointFound(I4C6)`) is
attributed to `com.google.android.gms.nearby.sharing` — ambient Quick Share, **not** this
flow.

### What this changes

- The C6 Fast Pair beacon is no longer on the critical path for the *trigger*. We can put
  the phone into the Source flow with one adb command.
- The remaining task is unchanged in spirit but clearer: the Mac must advertise a **Nearby
  Connections Target endpoint** declaring **device type = Chrome (8)**, so the waiting
  phone discovers it and connects. That is the `qsserve` discovery/advertising layer.
- Open question for the next session: does the phone, from this "continue setup on your
  new device" screen, actively discover a Target that advertises an NC endpoint — or does
  it still need the connection-request extra injected? Decisive test = stand up the Mac NC
  Target advertiser (device type Chrome) and watch whether the phone connects. Medium is
  likely NC "fast" BLE advertisement (service UUID 0xFEF3 + endpoint info — custom service
  data, so still needs an external radio or a dongle) or Bluetooth Classic SDP (doable on
  macOS via IOBluetooth, no extra radio). Confirm by decompiling the GMS `smartdevice`
  module or by trying the BT-Classic advertiser first.

## Mac NC-endpoint spec — from GMS 26.45.31 decompile (2026-11-23)

Decompiled `base.apk` (code is all in `classes*.dex`, not Chimera modules). Concrete
values the Mac must match to be the Quick Start **Target**:

- **Nearby Connections service ID**: `com.google.android.gms.smartdevice.NC_ID`
  (phenotype `nearby_connections_service_id`; same for source and target).
- **Strategy**: `P2P_POINT_TO_POINT`.
- **Mediums**:
  - Source **discovers** over `{BLE(4), Bluetooth-Classic(2)}` by default (BLE-only if a
    phenotype flag is set).
  - Target **advertises** over `{Bluetooth-Classic(2), BLE(4)}`, upgrade over both.
  - The actual data **connection** (requestConnection ConnectionOptions) is **Bluetooth
    Classic (2)**.
  - **So the Mac can be the Target over Bluetooth Classic natively (IOBluetooth RFCOMM) —
    no external BLE radio needed.** The C6 is off the critical path for both trigger and
    transport.
- **BLE fast-adv UUID** (if the BLE path is ever used): `0000FEF3-0000-1000-8000-00805F9B34FB`.

### Target endpoint-info byte layout (what the Mac advertises / the phone parses)

Wrapper `ConnectionsAdvertisementV1` (`ghny`): `0x01` version + deviceName (UTF-8,
null-terminated) + Base64(`AdvertisementDataV1`), padded to 60 bytes when the long-id flag
is set. `AdvertisementDataV1` (`ghns`) bytes:

| byte | meaning |
|------|---------|
| b[0] | verification style |
| **b[1]** | **device type — `8` = CHROME** (enum `ghpc`; Chromebook target = 8) |
| b[2..6] or b[2..11] | advertising id (UTF-8; 5 bytes, or 10 when b[12]=1) |
| b[7],b[8] | sub-field of the id region |
| b[12] | long-id / Quick Start flag (1 ⇒ 10-byte id) |
| b[13] | pin/verification UI style |
| b[14] | capability byte |
| b[15] | pin-fallback-supported (1=yes) |

(Note: a *different* enum `ggyy` uses Chrome=7 for `D2DDevice` name-mapping; but the byte
written into the NC advertisement is `ghpc`, Chrome=**8**.)

### Two ways to trigger the Source (both from adb, no beacon)

1. **Discovery route** — `am start -a ...SOURCE_DEVICE_SETUP` with a **`deeplink` Uri**
   extra. `SourceQuickStartChimeraActivity` reads advertisingId = `uri.getLastPathSegment()`
   and OOB key = `uri.getQueryParameter("key")`, builds a `ConnectionRequest` with
   device=null → the source then **discovers** (BLE+BT-Classic) for a Target advertising
   that advertising id. Mac must advertise the endpoint (above) with the matching id.

2. **Direct-inject route (skips discovery)** — provide a full `ConnectionRequest` whose
   `D2DDevice` is non-null. `D2DSetupChimeraActivity` reads a **String extra
   `"connectionRequest"`** = Base64 SafeParcelable (`brpg.c(..., ConnectionRequest.CREATOR)`);
   the binder `ISourceQuickStartService.connect(...)` takes one too. When `D2DDevice` is set
   (+ a flag), the source connector **skips discovery and requestConnection's straight to the
   endpoint** (`ghbf.java:241`), using `D2DDevice.deviceId` (= NC endpoint id) and
   `bluetoothMacAddr`. Populate `D2DDevice{deviceId, bluetoothMacAddr=<Mac BT MAC>,
   deviceType=CHROME}` → the phone dials the Mac's RFCOMM endpoint directly. Most
   deterministic; immune to the BLE-only discovery flag.

`ConnectionRequest` fields: `device(D2DDevice), pin, deeplinkPairingCode(=advertisingId),
fastpairCode(byte[]), outOfBandKey, triggerType(int), isQuickStartReconnect, isQuickStartConnection,
requiresLongTimeout, oemType(int), targetDeviceType(int)`.
`D2DDevice` fields: `protocol(int, default 2), name, deviceId, deviceType(byte), btUuid(dep),
cryptAuthHello(byte[], dep), bluetoothMacAddr, verificationStyle(int)`.

### What's left to build (Mac side)

The remaining work is a real protocol implementation, no longer a mystery gate: the Mac must
speak **Nearby Connections over Bluetooth Classic** — RFCOMM service under service ID
`com.google.android.gms.smartdevice.NC_ID`, P2P_POINT_TO_POINT, then the NC connection frames,
UKEY2 auth, and the d2d / Better Together payload that actually flips Phone Hub on.

**Existing Mac state (PhoneHubKit) vs the gap:** the Swift side already has the NC service
id `com.google.android.gms.smartdevice.NC_ID`, the UKEY2 handshake → encrypted D2D channel
(`NearbyConnection.swift`), NC framing (`NearbyFrames.swift`), enrollment/device-sync, and
endpoint advertising — but its transport is **Wi-Fi LAN** (TCP socket + Bonjour/mDNS,
`NearbyTransport.swift` / `NearbyAdvertiser.swift`). The decompile shows Quick Start's Source
flow **does not discover or bootstrap over Wi-Fi LAN** — it discovers over `{BLE, BT-Classic}`
and connects over **BT-Classic** (Wi-Fi LAN is only a post-bootstrap *upgrade* medium). That
is why the mDNS advertiser is never found.

**The one missing piece:** a **Bluetooth-Classic RFCOMM bootstrap transport** on macOS
(IOBluetooth) under the NC service id, wired to the existing UKEY2/D2D/frame stack. The
direct-inject route makes this tractable — tell the phone the Mac's BT MAC via a
`connectionRequest`/`D2DDevice`, and it dials the Mac's RFCOMM channel directly (no inquiry
or device-name advertising needed, just an SDP record + RFCOMM listener). After bootstrap,
NC can upgrade to the existing Wi-Fi LAN transport for bulk data.

### Build status (2026-11-23)

`BluetoothClassicTransport.swift` is written and builds:
- `NearbyBt.serviceUuidBytes` computes the SDP service UUID from the service id
  (MD5 + v3/variant bits, confirmed against google/nearby `uuid.cc` /
  `bluetooth_classic.cc`). For NC_ID = **`5e164731-1999-3405-9061-08a610fd3787`**
  (runtime output matches).
- `RfcommFrameChannel` conforms to the new `FrameChannel` protocol (so
  `NearbyConnection`'s existing UKEY2/D2D state machine runs over it unchanged),
  reassembling the 4-byte length-prefixed frames from the RFCOMM byte stream.
- `RfcommNearbyServer` publishes the SDP record + accepts an incoming RFCOMM
  channel and hands it to `NearbyConnection`. Prints this Mac's BT MAC.
- Launch: `scripts/btserve.sh` (embeds `Info.plist` for the Bluetooth TCC usage
  string) → `phonehubkit-selftest btserve [seconds]`.

**Unverified / next (needs a real Terminal — the Claude sandbox blocks Bluetooth):**
run `scripts/btserve.sh` to confirm the IOBluetooth runtime works — that
`publishedServiceRecord(with:)` accepts the service dict and the open-notification
registers — and to read the Mac's BT MAC. Then build the trigger: construct a
serialized `ConnectionRequest{ D2DDevice{deviceId=<our NC endpoint id>,
bluetoothMacAddr=<Mac MAC>, deviceType=CHROME} }` and
`am start ...D2DSetupActivity --es connectionRequest <base64>` so the phone dials
the Mac's RFCOMM endpoint directly.

## Live BT-Classic session — what works, and the real wall (2026-11-23)

Spent a long live session with the phone (M2101K6P) + btserve + HCI snoop. Net: the
**Mac-side Bluetooth-Classic Nearby endpoint is fully validated**, but the **deeplink
trigger is a dead end** — it never discovers. Details:

### The `connectionRequest` inject is impossible
`D2DDevice.writeToParcel` does **not** serialize `bluetoothMacAddr` (it's a JSON-only
field, id 8, skipped by the parcel writer). So you cannot hand the phone the Mac's MAC.
The "dial the Mac directly, skip discovery" plan is dead — the phone must *discover* the
Mac, never be told where it is.

### The Mac works as a BT-Classic Nearby endpoint (proven)
`btserve` (RfcommNearbyServer) stands up correctly: SDP service published under
UUID `5e164731-1999-3405-9061-08a610fd3787` (= MD5-name-UUID of the service id),
RFCOMM channel, open-notification registered. The Mac broadcasts a valid Nearby
Bluetooth-Classic advertisement **as its Bluetooth (Computer) name**. Confirmed on-air
via the phone's HCI snoop: the phone's inquiry returned the Mac with a correct,
untruncated advertisement — header `0x23` (v1 + P2P_POINT_TO_POINT), service hash
`2d 10 3f` (= SHA256(service_id)[:3]), label "Chromebook", and the **advertising-id
decoded byte-for-byte equal to the deeplink's** (`10ac991faacb361702b4`). The Mac side
is correct.

Two macOS constraints discovered the hard way:
- **Discoverable only while the Bluetooth Settings pane is focused.** `blueutil
  --discoverable 1` fails ("couldn't switch in 10s"); the private
  `IOBluetoothPreferenceSetDiscoverableState` can't hold it headless. No way around this
  on the built-in radio.
- **The inquiry EIR truncates the Bluetooth name at ~128 chars.** The original
  advertisement (60-byte-padded advertisement_data → ~160-char name) got chopped to 129
  and was unparseable. Fix applied: short fixed device label + drop the 60-byte padding →
  ~70-char name that fits intact. (Also fixed a feedback loop where btserve used the
  current computer name — already the NC string — as the device label.)

### The real wall: the deeplink does NO discovery
HCI snoop + logcat together are decisive. The `signin.google/qs/...` deeplink (via
`am start ... VIEW`) launches `SourceQuickStartActivity` → logs
`[D2D,SourceDeviceConnectorNearbyConnections] Connect directly via out-of-band API`
and then **starts no Nearby discovery of its own** (no `startDiscovery` for the
quickstart client). The Bluetooth-Classic inquiry that *did* find the Mac was
`startDiscovery package:com.android.settings` — the **phone's Settings app**, incidental,
not Quick Start. The OOB path expects the endpoint to be **already cached from a
background BLE scan**, which the Mac cannot populate (CoreBluetooth can't emit the NC
BLE advertisement). So the deeplink can never find the Mac regardless of how perfect the
BT-Classic side is. **The deeplink is the wrong trigger.**

(Also observed: on this phone the running Nearby discovery — for Quick *Share* — uses
`advertisingMediums:[BLE]`. If Quick Start's discovery is likewise BLE-only in practice,
even the beacon flow wouldn't do a BT-Classic inquiry; untested.)

### Where it stands / next (needs the C6)
The only trigger that starts a real Quick Start discovery is the **Fast Pair beacon**
(the C6's job) → "Set up this Chromebook" → full flow → Nearby Discoverer scanning
`{BLE, BT-Classic}`. When the C6 arrives:
1. Flash the beacon firmware (`firmware/chromebook_beacon`, already written).
2. Run `scripts/btserve.sh`, set the printed (short) `ComputerName`, Bluetooth pane
   focused.
3. C6 emits the beacon; watch via HCI snoop whether the beacon-triggered discovery does a
   BT-Classic inquiry and finds + connects to the Mac.
4. If that discovery is BLE-only, the C6 must instead emit the **NC BLE advertisement**
   (0xFEF3 + endpoint info), not just the Fast Pair beacon.

### Tooling added
- `scripts/btserve.sh` prints the `scutil --set ComputerName` line + the `adb` trigger.
- HCI snoop workflow (no root): enable "Bluetooth HCI snoop log" in Developer Options,
  **toggle Bluetooth to activate it**, then `adb bugreport <zip>` contains
  `FS/data/misc/bluetooth/logs/btsnoop_hci.log`. Parser:
  `scratchpad/snoop.py` decodes inquiry / connection / the Mac's advertisement.
- The Nearby BT-Classic name is computed by `NearbyBt.btClassicDeviceName`.
