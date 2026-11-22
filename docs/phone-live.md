# First contact with a real phone

A real Android phone (Xiaomi Redmi Note 10 Pro, `M2101K6P`, MIUI 14 / Android 13)
was signed into the throwaway account. It immediately appeared in the account's
Better Together group, read by our DeviceSync client:

```
id=fiUyeEV5_84   name=Xiaomi M2101K6P
```

This confirms the phone side is live and the account/group plumbing works
end to end with a genuine device.

## What we can read from the group now

- **Phone's persistent BetterTogether public key** — `devicePublicKey` in the
  packet, 73 bytes, parses as a valid P256 GenericPublicKey. This is one of the
  two inputs the authenticator handshake needs.
- **Phone's deviceId and name** — plaintext.

## What is NOT available yet

- **`encryptedMetadata` is empty**, so the phone's **beacon seeds** (needed to
  scan for its BLE advertisement) and Bluetooth address are not published yet.
- The phone reports **"isn't linked to a Chromebook."**

Both are the same cause: the phone is enrolled and in the registry, but the
multidevice **setup / linking** has not happened. Beacon seeds, BLE advertising,
and the features only activate after a Chromebook links to the phone — the
"Set up" + PIN flow in the Chromebook UI.

## Next step

Reproduce the **multidevice setup / linking**: enable the Better Together host
feature so our (fake) Chromebook links to the phone. That is the PIN /
phone-permission flow from the reference screenshots, and it is what turns the
phone into an active host — advertising its EID over BLE and sharing full
metadata. This is now testable because the phone is live on the account.

After linking: scan/connect over BLE (BleRadio), run the handshake (we already
hold the phone's public key), then the features.

## Linking attempt (probe/link.py)

- `v1:batchSetFeatureStatuses` — enabling BETTER_TOGETHER_HOST on the phone
  (exclusively) and BETTER_TOGETHER_CLIENT on us returns **HTTP 200**. The server
  accepted the link from our side.
- `v1:batchNotifyGroupDevices` (to push the phone to re-sync immediately) **404s**
  on the public REST gateway — not exposed. So we can't force the phone to act;
  it must pick up the host flag on its own DeviceSync, or linking is finished from
  the phone's own Chromebook-linking screen.
- Right after, the phone's `encryptedMetadata` is still empty. Pending: the phone
  syncing (MIUI background limits may delay it) or a phone-side nudge.

Feature-type strings: `BETTER_TOGETHER_HOST` / `BETTER_TOGETHER_CLIENT`
(cryptauth_feature_type.cc). TargetService.DEVICE_SYNC = 2.

## The linking barrier (finding)

The phone's Chromebook-linking screen says **"go to your Chromebook to link your
device"** — i.e. linking is **Chromebook-initiated** and the phone stays passive
until a Chromebook reaches it. Our server-side host flag (batchSetFeatureStatuses
200) did not make the phone link, and we cannot push or verify it
(batchNotifyGroupDevices and batchGetFeatureStatuses both 404 on the public REST
gateway).

Conclusion: the server-side impersonation is complete (enroll → DeviceSync → join
group → host flag accepted), but completing the **live link** needs the Mac to
act as a nearby Chromebook over BLE — advertise, connect, and run the setup
handshake with the phone present. That is the remaining build, and it may still
hit a legitimacy check during the handshake. This is the real frontier; it needs
the Mac's BLE (advertising + handshake), not just server calls.

## BLE scan result (from the Mac, user's own Terminal)

The scanner works (bluetooth poweredOn; the harness sandbox blocks BT so it must
run in a real Terminal with Bluetooth granted). Nearby BLE traffic included
Google cross-device services — `FEF3` (Nearby/Quick Share, ~27-byte payload, NOT
a Phone Hub EID), `FE9F`, `FEB9` — plus Microsoft `FCF1` (Swift Pair) and various
named devices.

No Better Together / Phone Hub beacon (a short 2-byte EID under the advertising
service) was seen. And we could not recognise one anyway: it would need the
phone's beacon seeds, which live in the encrypted metadata the phone has not
published (because it is not linked). This empirically closes the loop: the phone
is not advertising for Phone Hub, and we cannot get it there without a real
Chromebook-initiated, proximity-verified setup. `FEF3` is confirmed as a live
Google cross-device advertising service (the scaffold's guessed service UUID).
