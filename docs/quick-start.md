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
- ⬜ **Nearby Connections** — the bulk. BLE + Wi-Fi mediums, UKEY2, framing;
  `auth_string` comes from this session. Best bootstrapped from NearDrop /
  rquickshare, which already run Nearby Connections on macOS.
- ⬜ second-device auth / account transfer.
