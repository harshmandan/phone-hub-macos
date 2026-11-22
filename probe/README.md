# Phone Hub feasibility probe

One question: will Google let a Mac enroll as a Chromebook, so the phone's
built-in Phone Hub turns on for it? This probe answers it without building
anything real. It is a throwaway test, not part of Tether.

**Use a throwaway Google account.** The probe registers a fake Chrome device
against the account. microG users do similar things daily, but a lockout is
possible, so don't risk your main account.

## What it is not

It does not touch the phone directly, does not do Bluetooth, and does not
implement any feature. It only registers the Mac with Google and checks whether
the phone then lists it. That is the whole gate.

## Setup

```bash
cd experiments/phonehub-probe
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## The three gates, in order

Each gate can stop the project. Run them in order; don't build the next until
the current one passes.

### Gate 1 — can the account get the `cryptauth` scope?

Get a master token once:

1. Sign the throwaway account in at <https://accounts.google.com/EmbeddedSetup>
   in a browser. After approving, copy the `oauth_token` cookie (starts
   `oauth2_4/`).
2. ```bash
   ./probe_auth.py mastertoken you@gmail.com <oauth_token>
   ```
   Save the master token it prints (starts `aas_et/`).

Test the scope:

```bash
./probe_auth.py cryptauth you@gmail.com <master_token>
```

- Prints an auth token → **gate 1 passed.**
- Scope/permission error → **gate 1 failed. Stop.** The device-auth path can't
  get this scope, so the Chromebook impersonation can't start.

### Gate 2 — does CryptAuth accept `device_type = CHROME`?

```bash
./probe_enroll.py you@gmail.com <master_token>
```

This builds the Chromebook `ClientAppMetadata` (device_type CHROME + the Phone
Hub feature list), gets a GCM token, and calls `syncKeys` then `enrollKeys`.

Read the `syncKeys` result:

- **HTTP 200 with `randomSessionId`** → **gate 2 passed.** Google accepts the
  Mac as a Chrome device. This is the big unknown cleared.
- **Error naming device/metadata/type** → **gate 2 failed. Stop.** CHROME is
  rejected from a non-Chrome token.
- **Error naming gcm / registration id** → inconclusive. The GCM token is the
  weak part of the probe; adjust `get_gcm_token.py` and retry. This is not a no.

### Gate 3 — does the phone see the Mac?

If gate 2 passed, look at the phone:

**Settings › Google › Devices & sharing** (or **All devices**).

- A new Chromebook appears → **green light. The whole idea is feasible.** Phone
  Hub, Smart Lock and tethering become a real (large) build in Swift inside
  Tether.
- Nothing appears → enrollment worked but multidevice setup needs more. Partial,
  not dead; worth more digging.

## Files

- `probe_auth.py` — gate 1 (auth + scope). Minimal deps.
- `metadata.py` — builds the CHROME `ClientAppMetadata`. The one real change from
  microG's Android flow.
- `pb.py` — tiny protobuf encoder, so no protoc toolchain is needed.
- `get_gcm_token.py` — GCM check-in (as Chrome) + CryptAuth registration. The
  least-certain part; the first thing to adjust if gate 2 is inconclusive.
- `probe_enroll.py` — gates 2 and 3 (syncKeys + enrollKeys).

## Honest state

Not run end-to-end — that needs your throwaway account. The protobuf encoding is
checked and correct. The auth and enrollment calls mirror microG's working code;
the GCM registration params are a best effort and are the likeliest thing to
need a tweak. Every call prints the raw server response so you can see exactly
which gate you hit.

## Where the constants came from

- microG `GmsCore`, `org/microg/gms/cryptauth/` — the working Android flow, API
  key, cert, endpoints, request shapes.
- Chromium `chromeos/ash/services/device_sync/` and
  `chrome/browser/ash/cryptauth/` — what a real Chromebook sends (device_type
  CHROME, feature list, GCM app id and sender).
