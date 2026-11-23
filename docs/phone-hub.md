# Phone Hub / Better Together — porting the feature layer to Swift

Research scoping (2026-11-23) of what comes *after* a live authenticated channel to the
phone exists. Short version: **layers 3–4 are the easiest remaining work** — nearly all
clean-proto over the channel we already proved live. The hard part stays the connection
(see `quick-start.md`).

## Transport & auth — reused, not rebuilt
Phone Hub runs over the **secure_channel service on Nearby Connections**, not legacy BLE
weave (`chromeos/ash/services/secure_channel/nearby_connection.cc`; `ble_weave_*` is the
old path). BLE is discovery-only (EID beacon); the data channel is the same Nearby stack +
UKEY2 + D2D handshake we already ported (`NearbyConnection.swift`, `SecureContext`). **No
new crypto.** Role flips in our favour: for Phone Hub the **phone** is the host that
beacons, and the **Chromebook (Mac) is the client that scans + connects out** — both
things macOS does natively (unlike Quick Start, where the Mac must advertise).

## Protocol (layer 4) — clean port
`chromeos/ash/components/phonehub/proto/phonehub_api.proto`. Framing is trivial:
**2-byte big-endian MessageType prefix + protobuf** (`message_sender_impl.cc`). Messages:
`PROVIDE_CROS_STATE` (Chromebook→phone hello), `PHONE_STATUS_SNAPSHOT` / `PHONE_STATUS_UPDATE`
(battery, signal, DND, ring status…), notifications (`Notification{title, text, actions[],
shared_image}`, with `DismissNotificationRequest` / `NotificationInlineReplyRequest`),
camera roll / recent photos (`FetchCameraRollItems…`, full files via a Nearby **file
payload**, thumbnails inline), ring-device (= find-my-phone), battery saver, feature setup.
Estimate: ~1–2k LOC Swift; do notifications + status + ring first.

NB: **hotspot/tethering is NOT in this proto** — Instant Tethering is a separate
secure_channel feature (`chromeos/ash/components/tether/`), its own port.

## Enablement (layer 3) — essentially done
Feature flags in `multidevice_setup.mojom` (`kPhoneHub=4`, notifications/camera-roll/task
sub-features gate on it). Once the account is signed in and a host phone is verified,
`SetFeatureEnabledState` is a **local client toggle, not a server gate**. The upstream gate
is CryptAuth v2 DeviceSync (enroll as CHROME, BetterTogether group, phone = verified host)
— **already returns 200s** from our probes; CryptAuth does not reject the faked Chromebook.

## Risks
1. **The connection wall (unchanged).** All of this assumes a live authenticated channel —
   the thing we're still blocked on. Porting Phone Hub doesn't move that wall.
2. **Attestation.** `CrosState` can carry a TPM-rooted soft-bind cert (`O=Chrome Device
   Soft Bind`) a Mac can't forge. BUT the generator is only built when **Eche (app
   streaming)** is enabled; core Phone Hub (status, notifications, camera roll, ring, DND)
   sends CrosState **without** it. So **Eche is out of reach** (also Android-version gated),
   but core Phone Hub is **not** hard-gated Chromebook-side. Open unknown: whether the
   *phone* enforces attestation for the core features — only a live phone answers it.
3. Camera-roll full files ride a Nearby **file payload**, not inline proto — extra
   plumbing. Some permission grants require a tap **on the phone**.

Key paths: `chromeos/ash/components/phonehub/proto/phonehub_api.proto`,
`.../message_sender_impl.cc`, `.../cros_state_sender.cc`;
`chrome/browser/ash/attestation/soft_bind_attestation_flow_impl.cc`;
`chromeos/ash/services/secure_channel/nearby_connection.cc`;
`chromeos/ash/services/multidevice_setup/public/mojom/multidevice_setup.mojom`.
