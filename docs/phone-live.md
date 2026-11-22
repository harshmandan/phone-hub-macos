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
