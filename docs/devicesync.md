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

1. **Real GCM registration.** ✅ Done. `get_gcm_token.py` now does a real
   Android check-in (synthetic device profile) then registers
   com.google.android.gms, and returns a valid InstanceID token. The old
   `PHONE_REGISTRATION_ERROR` was from checking in as a Chrome browser.
2. **Enroll the `DeviceSync:BetterTogether` key bundle.** ✅ Done. Enrollment
   now runs both bundles (`enrollSingleKeyResponses: [{}, {}]`), keys saved to
   `device_keys.json`.
3. **Group metadata.** ⬜ The remaining blocker. Retried syncMetadata still
   returns 400 because the request must carry `group_public_key` and
   `encrypted_metadata` (cryptauth_metadata_syncer_impl.cc:491-495). That needs:
   - a **group key pair** (P256) the device creates for the account's group;
   - the local **BetterTogetherDeviceMetadata** (device_id, name, public key,
     Bluetooth address, feature support) — see
     cryptauth_better_together_device_metadata.proto;
   - that metadata **encrypted with the group key**, and
     `need_group_private_key` set.
   This is the next build chunk: group-key creation + metadata encryption.

## Where this leaves feasibility

Unchanged and proven: Google accepts the Mac as a CHROME device and stores its
key. DeviceSync membership is ordinary protocol work (the three items above),
all defined in `chromeos/ash/services/device_sync`. No new acceptance unknowns.

A phone only appears in this list if the **same account** is signed in on a
phone with Better Together set up. The throwaway account has no phone, so even
after membership works, testing phone↔Mac needs a phone on that account.
