import Foundation
import CoreBluetooth

/// Advertise the Mac as a Chromebook: stand up the weave GATT service (TX/RX)
/// and advertise the service UUID + a Chromebook-ish name. Logs any connection.
///
/// Two known walls this runs into:
///  1. Apple CoreBluetooth only advertises local name + service UUIDs — it drops
///     service data, where the Better Together EID lives. So no EID beacon.
///  2. In the normal flow the phone advertises and the Chromebook scans; the Mac
///     advertising is not the role the handshake uses.
/// This exists to see empirically whether the phone connects anyway.
public final class Advertiser: NSObject {
    private var manager: CBPeripheralManager!

    public override init() { super.init() }

    public func run(seconds: Double) {
        setvbuf(stdout, nil, _IONBF, 0)
        manager = CBPeripheralManager(delegate: self, queue: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print("advertise done")
    }
}

extension Advertiser: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            print("bluetooth state not on:", peripheral.state.rawValue,
                  "(grant Bluetooth to the terminal)")
            return
        }
        let service = CBMutableService(type: BleRadio.gattServiceUUID, primary: true)
        let tx = CBMutableCharacteristic(type: BleRadio.txCharacteristicUUID,
                                         properties: [.notify], value: nil, permissions: [])
        let rx = CBMutableCharacteristic(type: BleRadio.rxCharacteristicUUID,
                                         properties: [.write, .writeWithoutResponse],
                                         value: nil, permissions: [.writeable])
        service.characteristics = [tx, rx]
        peripheral.add(service)

        // CoreBluetooth will honour the name + service UUID; service data is dropped.
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "eve",
            CBAdvertisementDataServiceUUIDsKey: [BleRadio.gattServiceUUID],
        ])
        print("advertising as a Chromebook (service \(BleRadio.gattServiceUUID.uuidString))…")
        print("note: macOS drops service data, so no EID is in the advertisement.")
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        print(error == nil ? "advertising started" : "advertise error: \(error!)")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        print("!! a central connected and subscribed:", central.identifier)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            print("!! received write (\(r.value?.count ?? 0) bytes):", r.value?.hex ?? "")
            peripheral.respond(to: r, withResult: .success)
        }
    }
}
