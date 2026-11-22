# DeviceSync: the Better Together device registry

`cryptauthdevicesync.googleapis.com/v1:syncMetadata` returns every device in the
account's Better Together group — device_id, device_name and public key in the
clear, per-device metadata encrypted. This is the list the phone reads to find
other devices. Implemented in `probe/device_sync.py`.

## Result so far (2026-11-22)

`syncMetadata` returns **HTTP 400 INVALID_ARGUMENT**. Expected — the device is
not a group member yet. Enrollment proved Google accepts the Mac (enrollKeys
200), but joining the Better Together group needs more than the user key we
enrolled.

## What group membership needs (the next build chunk)

1. **Real GCM registration.** `device_id` must be a real InstanceID and
   `device_id_token` the matching GCM token. Our current GCM step fails with
   `PHONE_REGISTRATION_ERROR` because the check-in is a Chrome-browser check-in;
   a real Android/GMS check-in + InstanceID register is needed.
2. **Enroll the `DeviceSync:BetterTogether` key bundle.** We only enrolled the
   user `PublicKey` bundle. The group uses a separate device key
   (`kCryptAuthDeviceSyncBetterTogetherKeyName`). syncKeys/enrollKeys must run
   for that bundle too.
3. **Group metadata.** First syncMetadata sends the device's own
   `group_public_key` and `encrypted_metadata` (the ClientAppMetadata encrypted
   with the group key). The server then returns the full group.

## Where this leaves feasibility

Unchanged and proven: Google accepts the Mac as a CHROME device and stores its
key. DeviceSync membership is ordinary protocol work (the three items above),
all defined in `chromeos/ash/services/device_sync`. No new acceptance unknowns.

A phone only appears in this list if the **same account** is signed in on a
phone with Better Together set up. The throwaway account has no phone, so even
after membership works, testing phone↔Mac needs a phone on that account.
