import Foundation
import CoreBluetooth

/// A plain BLE scanner: list what is advertising near the Mac, with service
/// UUIDs and service data. Used to see whether the phone is reachable / in a
/// linkable (advertising) state before building the full setup handshake.
public final class Scanner: NSObject {
    private var central: CBCentralManager!
    private var seen = Set<UUID>()

    public override init() { super.init() }

    public func run(seconds: Double) {
        setvbuf(stdout, nil, _IONBF, 0)  // unbuffered, so piped output isn't lost
        central = CBCentralManager(delegate: self, queue: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        print("scan done — \(seen.count) distinct device(s)")
    }

    private func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized (grant Bluetooth to the terminal)"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        default: return "unknown"
        }
    }
}

extension Scanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("bluetooth state:", stateName(central.state))
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            print("scanning…")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard seen.insert(peripheral.identifier).inserted else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "—"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString }.joined(separator: ",") ?? ""
        var sd = ""
        if let data = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            sd = data.map { "\($0.key.uuidString)=\($0.value.hex)" }.joined(separator: " ")
        }
        print("• \(name)  rssi=\(RSSI)  services=[\(services)]  serviceData=[\(sd)]")
    }
}
