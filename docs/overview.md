# Phone Hub on the Mac: research notes

Goal: have the Mac use the phone's built-in Android features (one-tap hotspot,
unlock, recent photos) the way a Chromebook does, instead of KDE Connect.

Status (2026-11-22): research only. Nothing has been built or run.

## Existing efforts

- No project runs Phone Hub, Instant Tethering or Smart Lock outside ChromeOS.
  [chromeos-linux](https://github.com/samukhin/chromeos-linux) lists Phone Hub
  as not working.
- [microG](https://github.com/microg/GmsCore) (`org/microg/gms/cryptauth/`) is
  the closest working code. It implements the CryptAuth v2 client and the v2
  protos, including the Better Together feature names.
- [NearDrop](https://github.com/grishka/NearDrop),
  [rquickshare](https://github.com/Martichou/rquickshare) and
  [airsync-mac](https://github.com/sameerasw/airsync-mac) share the UKEY2 /
  `securegcm` protos used for the phone connection.

## How a Chromebook connects (from Chromium source)

`chrome/browser/ash/cryptauth/` and `chromeos/ash/services/device_sync/`:

1. Register the device with Google (CryptAuth enrollment), declaring itself a
   Chrome device that supports Phone Hub, Smart Lock and tethering.
2. Sync the account's phones and their keys.
3. Connect to the phone over Bluetooth LE, set up a UKEY2 secure channel, then
   exchange each feature's messages.

Both ends authenticate against the same Google account. The phone side already
ships on every Android phone; only the desktop side is missing.

## Why this is hard

- The desktop registers through Chrome's own Google sign-in. A Mac does not have
  that, so it would have to borrow the Android sign-in path (microG's) and hope
  the server treats it the same. That is the first unknown and may block the
  whole approach.
- Smart Lock, tethering and camera roll each have their own message format on
  top of the secure channel. Each is separate work.
- It is unofficial and account-linked, so it can break on any Play Services or
  Chrome update.

## Verdict

High effort, uncertain payoff, and it leans on reverse-engineering a private
Google service tied to your main account. KDE Connect already gives Tether most
of this except one-tap hotspot and phone-unlock. Not worth starting unless the
sign-in question (point 1) turns out to be easy.

## Lower-risk alternatives

- Keep KDE Connect; add the features it does support that Tether lacks.
- A small companion app on the phone (drops the "no custom phone app" rule) adds
  unlock and webcam with none of the CryptAuth problems.
