// Chromebook Quick Start stand-in — Seeed XIAO ESP32-C6
//
// Plays the two BLE roles a real Chromebook plays during Quick Start; the Mac
// (btserve) does everything else over Bluetooth Classic.
//
// 1. Fast Pair beacon (verified against Chromium fast_pair_advertiser.cc):
//    FE2C + model id 30 68 46 (Chromebook) + Google mfr data 00E0 + 6-byte
//    advertising id. Non-connectable. Makes the phone show "Set up your Chromebook".
//
// 2. Nearby Connections BLE advertisement for service
//    com.google.android.gms.smartdevice.NC_ID (google/nearby mediums/ble):
//    a connectable legacy advert carrying a 17-byte header in FEF3 service data,
//    plus a GATT server (service FEF3, characteristic 00000000-0000-3000-8000-
//    000000000000) holding the full advertisement. That advertisement carries the
//    Mac's Bluetooth MAC, so after scanning the QR the phone GATT-reads it here
//    and then opens RFCOMM to the Mac.
//
// The stock Arduino C6 build allows one advertising set
// (CONFIG_BT_NIMBLE_MAX_EXT_ADV_INSTANCES=1), so the two adverts alternate.
//
// Bytes for (2) come from gen_nc_advert.py -> nc_advert.h. Re-run it if the Mac,
// endpoint id or advertising id change. ADVERTISING_ID must equal btserve's.

#include <NimBLEDevice.h>
#include "nc_advert.h"

static const uint8_t ADVERTISING_ID[6] = { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };

static uint8_t beacon_raw[] = {
  0x02, 0x01, 0x06,                          // Flags
  0x03, 0x03, 0x2C, 0xFE,                    // Complete 16-bit UUIDs: FE2C
  0x06, 0x16, 0x2C, 0xFE, 0x30, 0x68, 0x46,  // Service Data FE2C: 30 68 46
  0x09, 0xFF, 0xE0, 0x00,                    // Mfr data, company 0x00E0
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00         // + advertising id (setup())
};

// Flags + Service Data FEF3 (17-byte header) = 3 + 21 = 24 bytes.
static uint8_t nc_raw[3 + 4 + sizeof(NC_HEADER)] = {
  0x02, 0x01, 0x06,
  (uint8_t)(3 + sizeof(NC_HEADER)), 0x16, 0xF3, 0xFE
};
static const uint8_t nc_scan_rsp[] = { 0x03, 0x03, 0xF3, 0xFE };

static const uint32_t SLOT_MS = 250;
static NimBLEExtAdvertising* adv;
static bool showingBeacon = false;
static volatile int gattReads = 0;

class ReadLogger : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic*, NimBLEConnInfo& info) override {
    gattReads++;
    Serial.printf("GATT read of NC advertisement by %s\n", info.getAddress().toString().c_str());
  }
};

class ConnLogger : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo& info) override {
    Serial.printf("connected: %s\n", info.getAddress().toString().c_str());
  }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo& info, int reason) override {
    Serial.printf("disconnected: %s reason %d\n", info.getAddress().toString().c_str(), reason);
  }
};

static void showBeacon() {
  NimBLEExtAdvertisement a;
  a.setLegacyAdvertising(true);
  a.setConnectable(false);
  a.setScannable(false);
  a.addData(beacon_raw, sizeof(beacon_raw));
  adv->stop(0);
  adv->setInstanceData(0, a);
  adv->start(0);
}

static void showNearby() {
  NimBLEExtAdvertisement a;
  a.setLegacyAdvertising(true);
  a.setConnectable(true);
  a.setScannable(true);
  a.addData(nc_raw, sizeof(nc_raw));
  NimBLEExtAdvertisement rsp;
  rsp.setLegacyAdvertising(true);
  rsp.addData(nc_scan_rsp, sizeof(nc_scan_rsp));
  adv->stop(0);
  adv->setInstanceData(0, a);
  adv->setScanResponseData(0, rsp);
  adv->start(0);
}

void setup() {
  Serial.begin(115200);
  delay(300);
  memcpy(beacon_raw + 18, ADVERTISING_ID, 6);
  memcpy(nc_raw + 7, NC_HEADER, sizeof(NC_HEADER));

  NimBLEDevice::init("");
  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ConnLogger());
  NimBLEService* svc = server->createService(NimBLEUUID((uint16_t)0xFEF3));
  NimBLECharacteristic* ch = svc->createCharacteristic(
      NimBLEUUID("00000000-0000-3000-8000-000000000000"), NIMBLE_PROPERTY::READ);
  ch->setValue(NC_GATT_ADVERTISEMENT, sizeof(NC_GATT_ADVERTISEMENT));
  ch->setCallbacks(new ReadLogger());
  svc->start();
  server->start();

  adv = NimBLEDevice::getAdvertising();
  showBeacon();
  showingBeacon = true;
  Serial.println("Up: Fast Pair beacon + Nearby NC_ID advert alternating every 250 ms.");
}

void loop() {
  delay(SLOT_MS);
  if (showingBeacon) showNearby(); else showBeacon();
  showingBeacon = !showingBeacon;
  static uint32_t last = 0;
  if (millis() - last > 5000) {
    last = millis();
    Serial.printf("alive, GATT reads so far: %d\n", gattReads);
  }
}
