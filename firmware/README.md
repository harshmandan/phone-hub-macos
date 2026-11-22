# Chromebook trigger beacon — firmware

`chromebook_beacon/chromebook_beacon.ino` makes a **Seeed XIAO ESP32-C6** broadcast the
BLE Fast Pair beacon that ChromeOS Quick Start emits, so a nearby Android phone shows the
**"Set up this Chromebook"** prompt. See `../docs/quick-start.md` for why this is the one
signal the Mac can't send itself.

## Flash it (Arduino IDE)

1. Install the **ESP32 boards package** (core 3.x): Arduino IDE → Settings → Additional
   Boards URLs → `https://espressif.github.io/arduino-esp32/package_esp32_index.json`,
   then Boards Manager → install **esp32** by Espressif.
2. Plug the XIAO C6 into the Mac with a **USB-C data cable**.
3. Tools → Board → **XIAO_ESP32C6**. Tools → Port → the new `/dev/cu.usbmodem…`.
4. Open `chromebook_beacon/chromebook_beacon.ino` → Upload.
   (If upload fails: hold **BOOT**, tap **RESET**, release BOOT, upload again.)
5. Serial Monitor at **115200** should print `Beacon up: FE2C + 30 68 46 …`.

## Test it

- Phone signed into the **target Google account**, Bluetooth on, screen unlocked.
- Bring it within ~30 cm of the board.
- Watch for a **"Set up this Chromebook" / "Set up nearby device"** notification, or check
  **Settings → Google → Devices & sharing / Set up & restore**.

**If the prompt appears:** the beacon works — move to completing the handshake on the Mac
(Nearby Connections + UKEY2, already built). The `advertising_id` in the sketch must then
match the id the Mac advertises (see the comment in the `.ino`).

**If nothing appears:** the beacon alone may not be enough (the phone-side match lives in
Google Play Services, closed-source). Next things to try: a random BLE address, confirming
the bytes on air with a scanner (nRF Connect app), or the Bumble + dongle path to iterate
the payload quickly. See `../docs/quick-start.md`.

## Notes

- Advertisement is **scannable, non-connectable** — the phone reads the beacon and connects
  to the *Mac's* Nearby channel, not to this board.
- Service data (`30 68 46`) rides in the ADV packet; manufacturer data (Google `0x00E0` +
  16-byte id) rides in the **scan response** (won't all fit one 31-byte packet).
- Default onboard antenna is used — fine at close range.
