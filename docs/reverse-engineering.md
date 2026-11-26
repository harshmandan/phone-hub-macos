# Reverse engineering Google Phone Hub for macOS

This is the full technical record of making a Mac act as a ChromeOS "Chromebook"
so a **stock, unrooted** Android phone relays its built-in cross-device features
to the Mac — with **no app installed on the phone**. Everything here was learned
by reading microG / Chromium source, decompiling Google Play Services (GMS), and
observing a live Pixel 9 (Android 16, GMS 26.45.31) over `adb` and logcat.

The headline: **every protocol layer works end to end.** The Mac enrolls with
Google as a Chrome device, wakes the phone's Nearby listener over Bluetooth LE,
opens the encrypted Phone Hub channel, and streams live phone status, camera-roll
photos, Instant Tethering, and notifications. The honest wall is not the protocol
— it is a notification filter baked into GMS that drops almost everything a normal
user considers a "notification". That filter is documented in detail below.

---

## 1. Architecture

The Mac speaks two Google protocols to the phone at the same time, on two
Bluetooth transports, so the client runs as **two cooperating processes**:

```
┌────────────────────────── PhoneHub.app (SwiftUI menu bar) ──────────────────────────┐
│  PhoneHubEngine  ── spawns & supervises ──►  bleweave   (CoreBluetooth, BLE central) │
│       │                                      phonehub   (IOBluetooth, RFCOMM)        │
│       └── parses EVENT json lines from both, publishes @Published UI state           │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

- **`bleweave`** — BLE central. Scans for the phone, runs **uWeave** over a GATT
  service, then a **Device-to-Device (D2D / UKEY2)** handshake. This is the
  "Better Together" weave channel. Its only job for Phone Hub is to **arm** the
  phone: the phone only advertises/accepts its Nearby "secure_channel" RFCOMM
  listener while an authenticated weave channel is live.
- **`phonehub`** — connects over **Bluetooth Classic RFCOMM** (Nearby
  Connections), repeats the D2D handshake over that transport, then exchanges
  `phone_hub` feature messages (status, notifications, camera roll, tethering).

Two processes because CoreBluetooth (BLE) and IOBluetooth RFCOMM can't share one
run loop cleanly. They run concurrently; the engine ties their output together.

---

## 2. Enrollment — the Mac becomes a "Chromebook"

Before any phone contact, the Mac registers itself with Google's CryptAuth /
DeviceSync (the "Better Together" device registry) exactly as a Chromebook does:

1. Obtain the `cryptauth` OAuth scope on a throwaway Google account.
2. `enrollKeys` — enroll a P-256 device key with `device_type = CHROME`.
3. `DeviceSync` — join the account's device group; the phone then lists the Mac
   as a known companion and shares the **beacon seeds** and **long-term public
   key** the Mac needs to find and authenticate the phone.

Those seeds + keys are saved as a "phone identity" bundle and are the root of
everything the BLE/Nearby layers do. (See `docs/devicesync.md`,
`docs/enrollkeys-design.md`.)

---

## 3. BLE weave layer (`bleweave`)

### 3.1 Finding the phone — rotating EID beacons
The phone continuously advertises a **FE50** service-data beacon whose payload is
a rotating **EID** (ephemeral ID) derived from the shared beacon seeds and the
current time. The Mac computes the set of currently-valid EIDs
(`Eid.nearestEids(seeds, nowMs)`) and scans for a match, so it recognizes the
phone without any static identifier. Observed RSSI for a reliable link: **≈ −55
to −72 dBm** (phone within ~1 m). Weaker than ~−90 dBm and the connection stalls.

### 3.2 uWeave over GATT
After connecting, the Mac discovers the weave GATT service and runs **uWeave**, a
small framing protocol:

| | |
| --- | --- |
| GATT service | `B3B7E28E-A000-3E17-BD86-6E97B9E28C11` |
| write char (TX) | `00000100-0004-1000-8000-001A11000101` |
| indicate char (RX) | `00000100-0004-1000-8000-001A11000102` |

uWeave control packets: **ConnectionRequest** → the phone replies
**ConnectionResponse** (`0x81…`, accept) or **ConnectionClose** (`0x92`, reject).
Data packets then carry the D2D messages, fragmented to the MTU.

### 3.3 D2D / UKEY2 secure channel
Over uWeave data packets the Mac runs the **DeviceToDevice** handshake (the same
UKEY2-based auth GMS uses): `[Initiator Hello]` → `[Responder Auth]` →
`[Initiator Auth]`, deriving a `SecureContext` (AES/HMAC session). Once this
authenticates, the phone considers a Better Together device present and **arms
its Nearby `secure_channel` RFCOMM listener**. That is the whole point of the
weave channel for Phone Hub.

---

## 4. Nearby Connections / RFCOMM layer (`phonehub`)

### 4.1 The secure_channel service and the rotating RFCOMM channel
The phone exposes a Nearby "secure_channel" service over Bluetooth Classic
RFCOMM. The **service UUID is stable** (a name-based MD5 UUID, prefix
`a384bd4f…`), but the **OS-assigned RFCOMM channel number rotates** — Android
calls `listenUsingInsecureRfcommWithServiceRecord`, and the channel is reassigned
(observed live: 10 → 12 → 13) whenever the listener restarts. Opening a stale
channel connects at the ACL level but no server socket is listening, so the open
hangs silently. **Fix:** always re-resolve the channel via SDP right before
opening, add an open timeout, and treat a silent hang as a miss and retry.

### 4.2 Second D2D handshake + WireMessage
The RFCOMM transport repeats the D2D handshake (it's a separate channel from BLE
weave), then every application message is wrapped in a **WireMessage** frame
(feature name + encrypted payload) before the SecureContext encrypts it. Incoming
Nearby payloads arrive as chunked `PayloadTransfer` frames and are reassembled by
payload id until the `LAST_CHUNK` flag.

### 4.3 phone_hub messages
Each `phone_hub` payload starts with a 2-byte big-endian message type:

| type | name | direction |
| --- | --- | --- |
| 0 | PROVIDE_CROS_STATE | Mac → phone (we're a Chromebook; enable notifications/camera-roll) |
| 1 | PHONE_STATUS_SNAPSHOT | phone → Mac (full status + notifications) |
| 2 | PHONE_STATUS_UPDATE | phone → Mac (deltas) |
| 5 | RING_DEVICE_REQUEST | Mac → phone |
| 9 | DISMISS_NOTIFICATION_REQUEST | Mac → phone |
| 11 | NOTIFICATION_INLINE_REPLY_REQUEST | Mac → phone |
| 15 / 16 | FETCH_CAMERA_ROLL_ITEMS req/resp | metadata + thumbnails |
| 17 / 18 | FETCH_CAMERA_ROLL_ITEM_DATA req/resp | full-file availability |
| 19 | INITIATE_CAMERA_ROLL_ITEM_TRANSFER | start the file payload |
| 24 | FEATURE_SETUP_REQUEST | ask the phone to prompt for a grant |

`PhoneStatusSnapshot` fields that decode cleanly:
`properties(1){ battery=1, charging=2, signal_bars=5 (0–4), carrier=6,
android_version=13, camera_roll_access=15 }`, plus `notifications(2, repeated)`.

**There is no Wi-Fi SSID, no LTE/5G field** in the protocol — Phone Hub only
carries carrier + signal bars + battery. A real Chromebook shows the same subset.

---

## 5. Features confirmed working live

- **Phone status** — battery %, charging, signal bars, carrier, Android version.
- **Camera roll** — recent photos/videos: metadata + inline thumbnails, plus
  on-demand full-file transfer (verified: 12 items, full-res download).
- **Instant Tethering** — `magic_tether` over the BLE weave channel. The
  `ConnectTetheringRequest` turns on the phone's hotspot and returns SSID +
  password; the Mac then joins it with CoreWLAN (verified: Mac got an IP and
  routed through the phone, HTTP 204 reachability).
- **Ring / locate the phone.**
- **Notification inline reply / dismiss** — for notifications that are relayed
  (see the big caveat in §7).

---

## 6. Connection reliability — root causes and fixes

The link was flaky until each of these was found and fixed:

| Symptom | Real root cause | Fix |
| --- | --- | --- |
| Random mid-session drops, slow reconnects | On teardown, `bleweave` was killed abruptly, leaving a **stale weave session** on the phone; the phone then `ConnectionClose`-rejects the next request or accepts it but ignores the D2D `[Initiator Hello]`. | On `SIGTERM`, send a uWeave **ConnectionClose** before exiting so the phone frees the session immediately. This alone turned churn into stable multi-minute sessions. |
| 60 s stall after a rejected connect | On `ConnectionClose` from the phone, `bleweave` waited for a handshake that never came until the arm-timeout killed it. | Exit immediately on `ConnectionClose` so the supervisor retries in ~2 s (the retry is almost always accepted). |
| "Phone out of range" when the phone is adjacent | The 45 s arm-timeout fired on a slow handshake and declared range failure. | Neutral message + one auto-retry; longer timeout; reset the retry budget whenever a session succeeds. |
| Handshake drops right after `[Initiator Hello]` | GMS Nearby **throttles rapid reconnects**. | Growing backoff; settle; exit-on-premature-close so each retry is a fresh process. |
| Opening the RFCOMM channel hangs forever | **Channel rotation** (§4.1) — stale channel, no listener. | Re-resolve SDP + open timeout + retry; first-open-wins latch. |
| BLE connect hangs on weak signal | No connect timeout. | 12 s connect timeout + RSSI warning. |

Session lengths were also raised (arm 2 h, NC 1 h) so the link isn't recycled
every couple of minutes; a clean NC exit now re-establishes quietly instead of
surfacing "Connection dropped".

---

## 7. Notifications — the deep dive (and the real wall)

Phone status, photos, and tethering work. **Notifications are where Phone Hub's
design — not our implementation — sets a hard limit.** This was proven by
decompiling GMS and by enabling GMS's own gated debug logging on the phone.

### 7.1 Where notifications come from
GMS runs `com.google.android.gms.auth.proximity.phonehub.PhoneHubNotificationListenerService`,
a standard enabled `NotificationListenerService`. On connect, GMS's
`NotificationMediator` (obf. class `avvj`) calls the listener's
`getActiveNotifications()` and sends the result as a `PHONE_STATUS_SNAPSHOT`; new
ones arrive live via `onNotificationPosted` → `PHONE_STATUS_UPDATE`.

### 7.2 The filter: `e()` / `isSupportedNotification`
Every notification — snapshot and live — passes through one static method,
`PhoneHubNotificationListenerChimeraService.e(StatusBarNotification)`. Resolved
from smali, a notification is **kept only if all hold**:

1. **Not** a group summary (`notification.flags & FLAG_GROUP_SUMMARY (0x200)`).
2. **Not** in GMS's package deny list.
3. It is a "messaging" notification, meaning **either**:
   - `category == "call"` (a live, ringing call), **or**
   - it has an action that is a **free-form inline-reply `RemoteInput`**
     (`getSemanticAction()` ∈ {UNSPECIFIED, REPLY} **and** a `RemoteInput` with
     `getAllowFreeFormInput() == true`) **and** at least one of `android.title` /
     `android.text` / `android.picture` is non-empty.

Everything else is logged as *"isSupportedNotification(): notification is not a
messaging notification"* and dropped.

### 7.3 What actually happens on a full phone
Captured from GMS's own logs (debug logging enabled via
`setprop log.tag.ProximityAuth VERBOSE` + a GMS restart so the `static final`
logger re-reads the level at class load). For a phone with **26 active
notifications**:

```
8  → "notification is group summary"
2  → "notification is from app in deny list"
16 → "notification is not a messaging notification"
0  kept  →  getCurrentNotifications() Found 0 total notifications
```

Independently confirmed from three angles:
- **Android framework is not the cause.** `dumpsys notification` shows the
  PhoneHub listener enabled, bound, same user, with the default (all-types)
  listener filter — identical standing to KDE Connect, which syncs fine. The
  framework hands GMS all 26; the `0` is introduced by `e()` afterward.
- **CompanionDevice presence was a red herring.** The CDM association is stuck in
  `WAITING_FOR_PRESENCE`, but GMS never calls `notifyDeviceAppeared` /
  `startObservingDevicePresence` anywhere in the APK, and
  `cmd companiondevice simulate-device-appeared` did not change the result. CDM
  presence gates CDM *message delivery*, not the notification listener.

### 7.4 Why "some WhatsApp relay but not others"
Not random, and not about the image — it is purely whether the notification
carries a **quick-reply box**:

- A **personal chat** you can reply to → WhatsApp attaches a free-form `RemoteInput`
  reply action → **relayed**. (The one WhatsApp notification that ever came
  through was exactly this — a replyable chat; it happened to also have an image.)
- A **WhatsApp Business / marketing** message (e.g. "cleartrip", "H&M India")
  → WhatsApp offers only *Mark as read* + *Mute*, no reply box → **dropped**.

### 7.5 What can never be relayed
By `e()`'s rules, these are dropped on any Chromebook, real or emulated:

| Notification | Why it's dropped |
| --- | --- |
| **Bank / OTP SMS** (shortcode sender) | Google Messages attaches no reply action for non-replyable senders → "not a messaging notification". |
| **Missed call** | `category == "missed_call"`, not `"call"`; its actions ("Call back", "Message") are `startActivity`, not inline reply. |
| Promotional / marketing messages | No reply action. |
| Email (Gmail) | "Reply" opens the app (`startActivity`), not an inline `RemoteInput`. |
| Group summaries | `FLAG_GROUP_SUMMARY`. |
| App/system/ongoing notifications | No reply action. |

What **does** relay: replyable personal conversations (WhatsApp/SMS/RCS with a
reply box) and **live incoming calls** while ringing. Phone Hub is a mirror of
*things you can act on from a Chromebook*, not your whole notification shade — and
this is identical on genuine ChromeOS.

---

## 8. macOS specifics

- **Menu-bar accessory app** (`LSUIElement`). Opening Settings / sign-in windows
  needs a temporary `NSApp.setActivationPolicy(.regular)` so they focus.
- **Bluetooth permission (TCC)** is keyed to the app's **code signature**, not the
  bundle id. Ad-hoc signing changes the hash every build, so macOS re-prompts each
  install. Fix: sign every build with a **stable self-signed code-signing
  identity** (created once in the login keychain) so the grant persists. The BLE
  subprocess shares the app bundle's grant, so checking `CBCentralManager.authorization`
  in the main app is accurate.
- The Bash sandbox blocks Bluetooth; live BLE tests run the built app, not a
  sandboxed process.

---

## 9. Tooling used for the reverse engineering

- **adb + logcat** on a developer-mode phone: `cmd notification list`,
  `dumpsys notification --noredact`, `dumpsys companiondevice`, `cmd companiondevice`.
- **GMS decompile**: pull `base.apk` via `adb pull`; locate the right `classesN.dex`
  by grepping for log strings; decompile with **jadx** (Java) and **apktool**
  (authoritative smali when jadx mangles control flow).
- **Enabling GMS debug logs**: `bszu` loggers gate on `Log.isLoggable(tag, level)`
  cached at class load; `setprop log.tag.ProximityAuth VERBOSE` **plus** a GMS
  restart (`am force-stop com.google.android.gms`) makes the per-notification
  keep/drop lines print.

---

## 10. Bottom line

Everything a Chromebook does over the air with the phone is reproducible from a
Mac with no phone-side app: enrollment, BLE weave + D2D, Nearby/RFCOMM, live phone
status, camera roll, Instant Tethering, ring, and reply/dismiss. The connection is
stable once the weave session is torn down cleanly. The one feature that
disappoints is notifications — not because the channel fails, but because GMS only
ever hands a Chromebook replyable conversations and live calls. Bank SMS, OTPs,
missed calls, and app alerts are filtered out on the phone before anything is
sent, and no client (ours or a real Chromebook) can widen that.

## Credits / references

Protocol details read from microG (`GmsCore`), the Chromium ChromeOS source
(`chromeos/ash/services/{device_sync,secure_channel}`,
`chrome/browser/ash/phonehub`), and decompiled Google Play Services. Research
project only; uses a throwaway Google account.
