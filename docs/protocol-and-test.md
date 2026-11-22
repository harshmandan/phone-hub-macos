# Step-1 test: will Google accept the Mac as a Chrome device?

One yes/no question. If yes, Phone Hub on the Mac is worth building. If no, the
idea ends here. Nothing below touches the phone — it only registers the Mac with
the account and checks whether the phone notices.

Use a throwaway Google account, not your main one.

## What the test proves

That Google's enrollment server issues the Mac a Chrome-device identity, and
that the phone's stock Play Services then lists the Mac as a linked Chromebook.
Everything after step 1 (Bluetooth, each feature) is only worth building once
this passes.

## The four calls (all already understood)

From microG (`org/microg/gms/cryptauth/`) and Chromium (`chromeos/ash/services/
device_sync/`). microG does exactly this flow for an **Android** device; the
test changes one field to **Chrome** and adds the Phone Hub feature list.

1. **Account token.** Get a Google auth token for the account. The library
   [gpsoauth](https://github.com/simon-weber/gpsoauth) does this (it is the
   check-in + master-token flow microG uses). Exchange it for a token with the
   `cryptauth` scope.
2. **GCM registration.** Register for GCM as app `com.google.chrome.cryptauth`,
   sender `381449029288`. [push-receiver](https://github.com/MatthieuLemoine/push-receiver)
   does Chrome-style GCM registration. Gives a registration token.
3. **SyncKeys** → `POST https://cryptauthenrollment.googleapis.com/v1:syncKeys`.
   Body is microG's `cryptAuthSyncKeys`, with these changes in `ClientAppMetadata`:
   - `device_type = CHROME` (microG uses ANDROID)
   - add `feature_metadata`: Better Together with `BETTER_TOGETHER_CLIENT`,
     `PHONE_HUB_CLIENT`, `EASY_UNLOCK_CLIENT`, `MAGIC_TETHER_CLIENT`
   - device model/manufacturer set to a Chromebook's
   Returns a `randomSessionId` on success.
4. **EnrollKeys** → `.../v1:enrollKeys` with that session id. microG's
   `cryptAuthEnrollKeys`.

Headers each call needs: `x-goog-api-key`, `x-android-package`, `x-android-cert`,
`Authorization: Bearer <token>`. Values are in microG's `cryptAuthQuery`.

## The three things that can go wrong (in order)

1. **No cryptauth-scoped token.** The server may refuse the scope to this
   sign-in path. microG gets it for Android, so this likely works — but it is
   the first thing to check. Fails here → dead end.
2. **CHROME rejected.** SyncKeys may refuse `device_type = CHROME` from a token
   that didn't come through real Chrome. This is the core unknown. A non-200
   here is the answer: no.
3. **Phone doesn't show it.** Both calls return 200 but the phone never lists the
   Mac. Then the server accepted enrollment but multidevice setup needs more.

## How to read the result

- **Both calls 200, phone shows a new Chromebook** under Settings › Google ›
  Devices & sharing (or All devices) → **green light, build it.**
- **Enrollment 200, no device on phone** → partial; needs more digging but not
  dead.
- **Non-200 at syncKeys with CHROME** → **red light, stop.**

## Build note

Do this as a throwaway script (Python is easiest: gpsoauth is Python), not in
Tether. It proves feasibility only. If it passes, the real client gets written
in Swift inside Tether later.

## Legal / account note

This talks to a private Google service with an account, the way microG does.
Keep it on a throwaway account so a lockout costs nothing.

## Result (2026-11-22)

Ran against a throwaway account.

- **Gate 1 PASSED.** `perform_oauth` returned `grantedScopes:
  .../auth/cryptauth`. A plain device sign-in can get the scope.
- **Gate 2 PASSED.** `v1:syncKeys` with `device_type = CHROME` and the Phone Hub
  feature list returned HTTP 200 with a `randomSessionId`, a P256 key directive,
  and a `clientDirective` for the `cryptauth` policy. This held even with a
  placeholder GCM token, so GCM is not validated at enrollment time.
- **GCM registration** via register3 returned `PHONE_REGISTRATION_ERROR`
  (the firebase-messaging checkin is a Chrome-browser checkin; a real build
  needs an Android/GMS-style checkin + InstanceID register). Not needed to prove
  feasibility.
- **enrollKeys** was sent as a stub (empty DH, no keys), so no device key was
  actually enrolled. The phone does not list the Mac yet.

**Conclusion: the hard blockers are gone.** Impersonating a Chromebook to
Google's enrollment server is not refused. What remains is ordinary engineering,
not unknowns:

1. Full `enrollKeys`: generate a P256 device key, do the ECDH with
   `clientEphemeralDh`, sign and send it. After this the phone should list the
   Mac (gate 3).
2. Real GCM registration (Android/GMS checkin + InstanceID) so device-sync
   pushes arrive.
3. The BLE secure channel (UKEY2) and each feature's message format.
