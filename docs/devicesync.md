# DeviceSync: the Better Together device registry

`cryptauthdevicesync.googleapis.com/v1:syncMetadata` returns every device in the
account's Better Together group — device_id, device_name and public key in the
clear, per-device metadata encrypted. This is the list the phone reads to find
other devices. Implemented in `probe/device_sync.py`.

## Result so far (2026-11-22)

`syncMetadata` returns **HTTP 200**. The Mac is now a member of the account's
Better Together group, listed as `deviceId: dwGxZyBMFPg, deviceName: "Google
eve"`. This is the registry a phone reads. Only one device appears because the
throwaway account has no phone.

Getting here needed all three steps below.

## What group membership needs (the next build chunk)

1. **Real GCM registration.** ✅ Done. `get_gcm_token.py` now does a real
   Android check-in (synthetic device profile) then registers
   com.google.android.gms, and returns a valid InstanceID token. The old
   `PHONE_REGISTRATION_ERROR` was from checking in as a Chrome browser.
2. **Enroll the `DeviceSync:BetterTogether` key bundle.** ✅ Done. Enrollment
   now runs both bundles (`enrollSingleKeyResponses: [{}, {}]`), keys saved to
   `device_keys.json`.
3. **Group metadata.** ✅ Done. The device creates a group key pair, builds
   its BetterTogetherDeviceMetadata, and encrypts it with the group key using
   Google's securemessage scheme (AES-256-CBC + HMAC-SHA256, master key =
   SHA256(ECDH); ported in `securemessage.py`, round-trip unit-tested). The
   server accepted it on the first try.

## Where this leaves feasibility

Unchanged and proven: Google accepts the Mac as a CHROME device and stores its
key. DeviceSync membership is ordinary protocol work (the three items above),
all defined in `chromeos/ash/services/device_sync`. No new acceptance unknowns.

A phone only appears in this list if the **same account** is signed in on a
phone with Better Together set up. The throwaway account has no phone, so even
after membership works, testing phone↔Mac needs a phone on that account.
