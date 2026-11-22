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
// A single 31-byte legacy ADV can't hold all of it, so the manufacturer data goes in
// the scan response. The advertisement is scannable + non-connectable (SCAN_IND):
// the phone active-scans, reads both packets, and connects to the Mac's Nearby
// Connections channel (not to this board).
//
// Toolchain: Arduino IDE with the ESP32 boards package (core 3.x). Uses the ESP-IDF
// Bluedroid raw GAP API for byte-exact control. See ../README.md to flash.

#include "esp_gap_ble_api.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include <string.h>

// 16-byte advertising id carried in the beacon's manufacturer data.
// For the first "does the prompt appear?" test ANY value works.
// For the full flow this MUST match the id the Mac advertises in its Nearby
// Connections endpoint (qsserve) so the phone links the beacon to the channel.
static uint8_t advertising_id[16] = {
  0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
  0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xF0, 0x0F
};

// ADV packet: Flags + 16-bit Service UUID list (FE2C) + Service Data (FE2C + 30 68 46)
static uint8_t adv_raw[] = {
  0x02, 0x01, 0x06,                          // Flags: LE General Disc, BR/EDR not supported
  0x03, 0x03, 0x2C, 0xFE,                    // Complete list of 16-bit Service UUIDs: 0xFE2C
  0x06, 0x16, 0x2C, 0xFE, 0x30, 0x68, 0x46   // Service Data 16-bit: 0xFE2C, data = 30 68 46
};

// Scan response: Manufacturer Specific Data, company 0x00E0 + 16-byte advertising id.
// [len=0x13(19)] [type=0xFF] [company LE E0 00] [16 bytes id]
static uint8_t scan_rsp_raw[20] = { 0x13, 0xFF, 0xE0, 0x00 };  // id copied in setup()

static esp_ble_adv_params_t adv_params;

static void gap_cb(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
  switch (event) {
    case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
      esp_ble_gap_config_scan_rsp_data_raw(scan_rsp_raw, sizeof(scan_rsp_raw));
      break;
    case ESP_GAP_BLE_SCAN_RSP_DATA_RAW_SET_COMPLETE_EVT:
      esp_ble_gap_start_advertising(&adv_params);
      break;
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
      Serial.println(param->adv_start_cmpl.status == ESP_BT_STATUS_SUCCESS
                       ? "Beacon up: FE2C + 30 68 46 (Chromebook). Bring the phone close."
                       : "ERROR: advertising failed to start");
      break;
    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);
  memcpy(scan_rsp_raw + 4, advertising_id, 16);

  // XIAO ESP32-C6 uses its onboard antenna by default — fine at close range.
  // (External u.FL antenna select is a separate GPIO; not needed for a bench test.)

  esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
  if (esp_bt_controller_init(&bt_cfg) || esp_bt_controller_enable(ESP_BT_MODE_BLE) ||
      esp_bluedroid_init() || esp_bluedroid_enable()) {
    Serial.println("ERROR: BLE stack init failed");
    return;
  }

  adv_params.adv_int_min       = 0x20;                           // 20 ms
  adv_params.adv_int_max       = 0x40;                           // 40 ms
  adv_params.adv_type          = ADV_TYPE_SCAN_IND;             // scannable, non-connectable
  adv_params.own_addr_type     = BLE_ADDR_TYPE_PUBLIC;
  adv_params.channel_map       = ADV_CHNL_ALL;
  adv_params.adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY;

  esp_ble_gap_register_callback(gap_cb);
  esp_ble_gap_config_adv_data_raw(adv_raw, sizeof(adv_raw));    // chain: adv -> scan_rsp -> start
}

void loop() {
  delay(1000);
}
