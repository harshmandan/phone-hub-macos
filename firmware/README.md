# Chromebook trigger beacon — firmware

`chromebook_beacon/chromebook_beacon.ino` makes a **Seeed XIAO ESP32-C6** broadcast the
BLE Fast Pair beacon that ChromeOS Quick Start emits, so a nearby Android phone shows the
**"Set up this Chromebook"** prompt. See `../docs/quick-start.md` for why this is the one
signal the Mac can't send itself.

## Status: toolchain ready, sketch compiles

Already installed on this Mac (via `brew` + `arduino-cli`), so there's nothing to set up
when the board arrives:
- Arduino IDE (`/Applications/Arduino IDE.app`)
- `arduino-cli` 1.5.1, ESP32 core **esp32:esp32 4.0.0**, **NimBLE-Arduino 2.5.2**
- The sketch **compiles clean** for `esp32:esp32:XIAO_ESP32C6` (51% flash).

The C6 ships with NimBLE (Bluedroid is off) and extended advertising on, so the sketch uses
`NimBLEExtAdvertisement` in **legacy mode** — a classic scannable, non-connectable PDU, which
is what the phone's Fast Pair scanner expects.

## Flash it (when the board arrives)

Plug the XIAO C6 into the Mac with a **USB-C data cable**, then either:

**Command line (simplest):**
```
cd /Users/harsh/Developer/phone-hub-macos
arduino-cli board list                       # find the port, e.g. /dev/cu.usbmodem1101
arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32C6 firmware/chromebook_beacon
arduino-cli upload  --fqbn esp32:esp32:XIAO_ESP32C6 -p <PORT> firmware/chromebook_beacon
arduino-cli monitor -p <PORT> -c baudrate=115200
```
(If upload fails: hold **BOOT**, tap **RESET**, release BOOT, upload again.)

**Arduino IDE:** open the `.ino`, Tools → Board → **XIAO_ESP32C6**, pick the port, Upload,
then open Serial Monitor at **115200**.

Either way the serial output should print `Beacon up: FE2C + 30 68 46 …`.

## Test it

- Phone signed into the **target Google account**, Bluetooth on, screen unlocked.
- Bring it within ~30 cm of the board.
- Watch for a **"Set up this Chromebook" / "Set up nearby device"** notification, or check
  **Settings → Google → Devices & sharing / Set up & restore**.

**If the prompt appears:** the beacon works — move to completing the handshake on the Mac
(Nearby Connections + UKEY2, already built). The `advertising_id` in the sketch must then
match the id the Mac advertises (see the comment in the `.ino`).

**If serial prints `ERROR: advertising failed to start`:** NimBLE rejected the scannable
legacy adv-data layout — tell me and I'll shift the bytes (e.g. move the service UUID list,
or carry more in the scan response).

**If it advertises but no phone prompt appears:** the beacon alone may not be enough (the
phone-side match lives in Google Play Services, closed-source). Next: confirm the bytes on
air with the **nRF Connect** app, try a random BLE address, or switch to the Bumble + dongle
path to iterate quickly. See `../docs/quick-start.md`.

## Notes

- Advertisement is **scannable, non-connectable** — the phone reads the beacon and connects
  to the *Mac's* Nearby channel, not to this board.
- Service data (`30 68 46`) rides in the ADV packet; manufacturer data (Google `0x00E0` +
  16-byte id) rides in the **scan response** (won't all fit one 31-byte packet).
- Default onboard antenna is used — fine at close range.
