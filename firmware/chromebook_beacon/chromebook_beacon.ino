// Chromebook "Set up this Chromebook" trigger beacon — Seeed XIAO ESP32-C6
//
// Broadcasts the BLE Fast Pair beacon that ChromeOS Quick Start emits during setup,
// so a nearby Android phone (signed into the target Google account) raises the
// "Set up this Chromebook" prompt. The Mac can't send this (CoreBluetooth ignores
// custom service/manufacturer advertising data); this board supplies it.
//
// Beacon shape, from Chromium chrome/browser/ash/login/oobe_quick_start/connectivity/
// fast_pair_advertiser.cc:
//   - Service UUID 0xFE2C (Fast Pair)
//   - Service Data for 0xFE2C = model id {0x30,0x68,0x46}  (kFastPairModelIdChromebook)
//   - Manufacturer Specific Data: company 0x00E0 (Google) + 16-byte advertising id
// All of it won't fit one 31-byte legacy packet, so the manufacturer data goes in the
// scan response. The advertisement is scannable + non-connectable (ADV_SCAN_IND): the
// phone active-scans, reads both packets, and connects to the Mac's Nearby Connections
// channel (not to this board).
//
// The XIAO ESP32-C6 ships with NimBLE (Bluedroid is disabled for the C6) with extended
// advertising enabled, so this uses NimBLE-Arduino's NimBLEExtAdvertisement in LEGACY
// mode — a classic scannable, non-connectable PDU (ADV_SCAN_IND) with raw AD bytes, which
// is what the phone's Fast Pair scanner expects. See ../README.md.

#include <NimBLEDevice.h>
#include <string.h>

// 16-byte advertising id carried in the beacon's manufacturer data.
// For the first "does the prompt appear?" test ANY value works.
// For the full flow this MUST match the id the Mac advertises in its Nearby
// Connections endpoint (qsserve) so the phone links the beacon to the channel.
static uint8_t advertising_id[16] = {
  0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
  0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xF0, 0x0F
};

// ADV packet AD structures: Flags + 16-bit Service UUID list (FE2C) + Service Data (FE2C + 30 68 46)
static const uint8_t adv_raw[] = {
  0x02, 0x01, 0x06,                          // Flags: LE General Disc, BR/EDR not supported
  0x03, 0x03, 0x2C, 0xFE,                    // Complete list of 16-bit Service UUIDs: 0xFE2C
  0x06, 0x16, 0x2C, 0xFE, 0x30, 0x68, 0x46   // Service Data 16-bit: 0xFE2C, data = 30 68 46
};

// Scan response AD structure: Manufacturer Specific Data, company 0x00E0 + 16-byte id.
// [len=0x13(19)] [type=0xFF] [company LE E0 00] [16 bytes id]
static uint8_t scan_rsp_raw[20] = { 0x13, 0xFF, 0xE0, 0x00 };  // id copied in setup()

void setup() {
  Serial.begin(115200);
  delay(300);
  memcpy(scan_rsp_raw + 4, advertising_id, 16);

  // XIAO ESP32-C6 uses its onboard antenna by default — fine at close range.
  // (External u.FL antenna select is a separate GPIO; not needed for a bench test.)

  NimBLEDevice::init("");
  NimBLEExtAdvertising* pAdv = NimBLEDevice::getAdvertising();

  // Primary advertisement: legacy, scannable + non-connectable (ADV_SCAN_IND).
  NimBLEExtAdvertisement advData;
  advData.setLegacyAdvertising(true);
  advData.setConnectable(false);
  advData.setScannable(true);
  advData.addData(adv_raw, sizeof(adv_raw));

  // Scan response: the Google manufacturer data (doesn't fit the 31-byte ADV packet).
  NimBLEExtAdvertisement scanData;
  scanData.setLegacyAdvertising(true);
  scanData.addData(scan_rsp_raw, sizeof(scan_rsp_raw));

  bool ok = pAdv->setInstanceData(0, advData)
            && pAdv->setScanResponseData(0, scanData)
            && pAdv->start(0);
  Serial.println(ok
                   ? "Beacon up: FE2C + 30 68 46 (Chromebook). Bring the phone close."
                   : "ERROR: advertising failed to start");
}

void loop() {
  delay(1000);
}
