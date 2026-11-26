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
    // The phone advertises its presence EID as service DATA under FE50; the
    // actual uWeave GATT service is a SEPARATE UUID (b3b7e28e), with the
    // post-uWeave-migration TX/RX characteristics (ble_constants.h /
    // ble_weave_client_connection current values).
    static let advertServiceUUID = CBUUID(string: "0000FE50-0000-1000-8000-00805F9B34FB")
    static let gattServiceUUID = CBUUID(string: "b3b7e28e-a000-3e17-bd86-6e97b9e28c11")
    // This GMS build exposes the pre-migration weave characteristics (confirmed
    // live by enumerating the b3b7e28e service): TX = …0101 [write],
    // RX = …0102 [indicate].
    static let txCharacteristicUUID = CBUUID(string: "00000100-0004-1000-8000-001A11000101")
    static let rxCharacteristicUUID = CBUUID(string: "00000100-0004-1000-8000-001A11000102")

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

    /// Start scanning and block on the run loop for `seconds` (synchronous, so it
    /// is callable from the async `main` without the run(until:) async warning).
    public func run(seconds: Double) {
        start()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print("bleweave done")
    }

    public func start() {
        setvbuf(stdout, nil, _IONBF, 0)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let eids = Eid.nearestEids(remoteSeeds, nowMs: now).map { $0.eid.hex }
        log("start — phone's current EIDs: \(eids.joined(separator: " "))")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func log(_ s: String) { print("  [ble] \(s)") }

    private func send(_ packet: Data) {
        guard let p = peripheral, let tx else { return }
        // Match the characteristic: this phone's TX is [write] (with response),
        // not writeWithoutResponse — a mismatched type is silently dropped.
        let type: CBCharacteristicWriteType =
            tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        log("→ write \(packet.count)B [\(type == .withResponse ? "withResp" : "noResp")]: \(packet.prefix(32).hex)")
        p.writeValue(packet, for: tx, type: type)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("write error: \(error.localizedDescription)") }
    }
}

extension BleRadio: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state: \(central.state.rawValue) (5=poweredOn)")
        if central.state == .poweredOn {
            // Scan everything (the phone's FE50 presence EID is service DATA, not
            // always in the advertised service-UUID list) with duplicates so a
            // rotating/intermittent advert isn't missed.
            central.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log("scanning for the phone's FE50 EID …")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Match the phone's rotating EID in the FE50 service data.
        guard let eidData = serviceData[Self.advertServiceUUID],
              Eid.matches(advertisementServiceData: eidData, remoteSeeds: remoteSeeds, nowMs: now) else { return }
        log("★ phone found — FE50=\(eidData.hex) rssi=\(RSSI) name=\(peripheral.name ?? "?"); connecting …")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("connected ✅ — discovering weave service b3b7e28e …")
        peripheral.discoverServices([Self.gattServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("didFailToConnect: \(error?.localizedDescription ?? "?") — rescanning")
        self.peripheral = nil
        central.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "clean"); rescanning")
        self.peripheral = nil; self.tx = nil
        central.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
}

extension BleRadio: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let found = (peripheral.services ?? []).map { $0.uuid.uuidString }
        log("services: \(found.isEmpty ? "none" : found.joined(separator: ", "))")
        for service in peripheral.services ?? [] where service.uuid == Self.gattServiceUUID {
            // Discover ALL characteristics — the exact TX/RX UUIDs vary by GMS
            // version, so enumerate and log what this phone actually exposes.
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            var props: [String] = []
            if c.properties.contains(.write) { props.append("write") }
            if c.properties.contains(.writeWithoutResponse) { props.append("writeNoResp") }
            if c.properties.contains(.notify) { props.append("notify") }
            if c.properties.contains(.indicate) { props.append("indicate") }
            if c.properties.contains(.read) { props.append("read") }
            log("  char \(c.uuid.uuidString)  [\(props.joined(separator: ","))]")
        }
        for c in service.characteristics ?? [] {
            if c.uuid == Self.txCharacteristicUUID { tx = c }
            if c.uuid == Self.rxCharacteristicUUID { peripheral.setNotifyValue(true, for: c) }
        }
        guard tx != nil else { log("no TX characteristic — weave service mismatch?"); return }
        // uWeave starts with a connection request.
        log("→ uWeave ConnectionRequest")
        send(generator.connectionRequest())
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.rxCharacteristicUUID, let value = characteristic.value else { return }
        log("← weave rx \(value.count)B: \(value.prefix(48).hex)")
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
