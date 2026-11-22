import Foundation
import CoreBluetooth

/// The CoreBluetooth radio: the Mac acts as BLE central, finds the phone by its
/// rotating EID, connects, and runs uWeave over the TX/RX characteristics.
///
/// SCAFFOLD. The discovery → connect → weave framing is wired to the tested
/// `Eid` and `Weave` code. The parts marked `PHONE-GATED` (the authenticator
/// handshake and each feature) need a phone on the account to build against and
/// cannot be exercised here. Nothing in this file is verified yet — unlike the
/// rest of PhoneHubKit, it has no tests because it needs hardware.
///
/// GATT UUIDs from chromeos/ash/services/secure_channel (ble_weave_client_
/// connection.cc). The advertising service UUID is marked to confirm against a
/// real phone — the source file would not fetch cleanly.
public final class BleRadio: NSObject {
    // Confirmed from source.
    static let txCharacteristicUUID = CBUUID(string: "00000100-0004-1000-8000-001A11000101")
    static let rxCharacteristicUUID = CBUUID(string: "00000100-0004-1000-8000-001A11000102")
    // TODO(phone): confirm the advertising/GATT service UUID against a device.
    static let serviceUUID = CBUUID(string: "0000FEF3-0000-1000-8000-00805F9B34FB")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private let receiver = Weave.PacketReceiver()
    private let generator = Weave.PacketGenerator()

    /// The remote phone's beacon seeds (from its DeviceSync metadata), used to
    /// recognise its rotating advertisement.
    private let remoteSeeds: [Eid.BeaconSeed]

    /// Called with each fully-reassembled secure-channel message.
    public var onMessage: ((Data) -> Void)?

    public init(remoteSeeds: [Eid.BeaconSeed]) {
        self.remoteSeeds = remoteSeeds
        super.init()
    }

    public func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func send(_ packet: Data) {
        guard let p = peripheral, let tx else { return }
        p.writeValue(packet, for: tx, type: .withoutResponse)
    }
}

extension BleRadio: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.serviceUUID])
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Match the phone's rotating EID carried in the advertisement service data.
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        guard let eidData = serviceData?[Self.serviceUUID],
              Eid.matches(advertisementServiceData: eidData, remoteSeeds: remoteSeeds,
                          nowMs: Int64(Date().timeIntervalSince1970 * 1000)) else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }
}

extension BleRadio: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.txCharacteristicUUID, Self.rxCharacteristicUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == Self.txCharacteristicUUID { tx = c }
            if c.uuid == Self.rxCharacteristicUUID { peripheral.setNotifyValue(true, for: c) }
        }
        // uWeave starts with a connection request.
        send(generator.connectionRequest())
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.rxCharacteristicUUID, let value = characteristic.value else { return }
        do {
            switch try receiver.receive(value) {
            case .control:
                break  // connection response / close
            case .incomplete:
                break  // more packets to come
            case .message(let message):
                handleChannelMessage(message)
            }
        } catch {
            // out-of-sequence / framing error — real code tears the link down
        }
    }

    private func handleChannelMessage(_ message: Data) {
        // PHONE-GATED. Before the channel is up, these bytes are handshake
        // messages ([ResponderAuth], …); after, they are feature messages
        // decoded through SecureContext. Both need the authenticator, which
        // needs the multidevice pairing — and a phone — to implement. See
        // docs/ble.md and docs/swift-client.md.
        onMessage?(message)
    }
}
