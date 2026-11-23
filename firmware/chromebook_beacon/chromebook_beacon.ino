// Chromebook "Set up this Chromebook" trigger beacon — Seeed XIAO ESP32-C6
//
// Broadcasts the BLE Fast Pair beacon that ChromeOS Quick Start emits during setup,
// so a nearby Android phone (signed into the target Google account) raises the
// "Set up this Chromebook" prompt and starts the Quick Start discovery. The Mac
// can't send this (CoreBluetooth ignores custom service/manufacturer advertising
// data); this board supplies it. The Mac (btserve) is the Bluetooth-Classic Nearby
// endpoint the phone then discovers + connects to.
//
// Beacon shape, verified against Chromium chrome/browser/ash/login/oobe_quick_start/
// connectivity/fast_pair_advertiser.cc (RegisterAdvertisement / GenerateManufacturerMetadata):
//   - Service UUID 0xFE2C (Fast Pair)
//   - Service Data for 0xFE2C = model id {0x30,0x68,0x46}  (kFastPairModelIdChromebook)
//   - Manufacturer Specific Data: company 0x00E0 (Google) + the advertising id
//   - Type = ADVERTISEMENT_TYPE_BROADCAST (non-connectable)
//
// IMPORTANT (corrected): the advertising id is **6 raw bytes** (AdvertisingId::kLength = 6),
// NOT 16 — the old 16-byte comment in fast_pair_advertiser.h is stale. With 6 bytes the
// whole thing fits one 31-byte legacy ADV packet (14B UUIDs+service-data + 10B mfr data),
// so no scan response is needed.
//
// The SAME 6 bytes must be what btserve advertises: btserve's advertising_id =
// these 6 bytes, and its Nearby endpoint info carries base64url(no-pad) of them
// (8 ASCII chars). Keep ADVERTISING_ID below equal to btserve's fixed id.
//
// The C6 ships with NimBLE (Bluedroid off) + extended advertising on, so this uses
// NimBLE-Arduino's NimBLEExtAdvertisement in LEGACY mode with raw AD bytes.

#include <NimBLEDevice.h>

// 6-byte advertising id — MUST equal btserve's fixed advertising_id (see
// RfcommNearbyServer in BluetoothClassicTransport.swift). The phone reads these
// raw bytes from the beacon, base64url-encodes them, and looks for a Nearby
// target advertising that id.
static const uint8_t ADVERTISING_ID[6] = { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };

// One ADV packet: Flags + Complete 16-bit Service UUIDs (FE2C) + Service Data
// (FE2C = 30 68 46) + Manufacturer Specific Data (company E0 00 + 6-byte id). 24 bytes.
static uint8_t adv_raw[] = {
  0x02, 0x01, 0x06,                          // Flags: LE General Disc, BR/EDR not supported
  0x03, 0x03, 0x2C, 0xFE,                    // Complete list of 16-bit Service UUIDs: 0xFE2C
  0x06, 0x16, 0x2C, 0xFE, 0x30, 0x68, 0x46,  // Service Data 16-bit: 0xFE2C, data = 30 68 46
  0x09, 0xFF, 0xE0, 0x00,                    // Mfr Specific Data: len 9, type 0xFF, company 0x00E0
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00         // + 6-byte advertising id (filled in setup())
};

void setup() {
  Serial.begin(115200);
  delay(300);
  memcpy(adv_raw + 18, ADVERTISING_ID, 6);   // id goes right after [len][FF][E0][00]

  NimBLEDevice::init("");
  NimBLEExtAdvertising* pAdv = NimBLEDevice::getAdvertising();

  // Legacy, non-connectable broadcast (ADVERTISEMENT_TYPE_BROADCAST). All data fits
  // the ADV packet, so no scan response. If the phone's scanner needs a scan
  // response, flip setScannable(true) and move the mfr data there.
  NimBLEExtAdvertisement advData;
  advData.setLegacyAdvertising(true);
  advData.setConnectable(false);
  advData.setScannable(false);
  advData.addData(adv_raw, sizeof(adv_raw));

  bool ok = pAdv->setInstanceData(0, advData) && pAdv->start(0);
  Serial.println(ok
                   ? "Beacon up: FE2C + 30 68 46 + id 11 22 33 44 55 66 (Chromebook)."
                   : "ERROR: advertising failed to start");
}

void loop() {
  delay(1000);
}
