import Foundation
import CoreBluetooth

/// A plain BLE scanner: list what is advertising near the Mac, with service
/// UUIDs and service data. Used to see whether the phone is reachable / in a
/// linkable (advertising) state before building the full setup handshake.
public final class Scanner: NSObject {
    private var central: CBCentralManager!
    private var seen = Set<UUID>()
    private var flagged = Set<UUID>()
    private let targetSeeds: [Eid.BeaconSeed]
    private let targetLabel: String

    public init(targetSeeds: [Eid.BeaconSeed] = [], targetLabel: String = "") {
        self.targetSeeds = targetSeeds
        self.targetLabel = targetLabel
        super.init()
    }

    public func run(seconds: Double) {
        setvbuf(stdout, nil, _IONBF, 0)  // unbuffered, so piped output isn't lost
        if !targetSeeds.isEmpty {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let eids = Eid.nearestEids(targetSeeds, nowMs: now).map { $0.eid.hex }
            print("looking for \(targetLabel) — current EIDs: \(eids.joined(separator: " "))")
        }
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

private func offset(of needle: Data, in hay: Data) -> Int? {
    guard needle.count <= hay.count, !needle.isEmpty else { return nil }
    let h = Array(hay), n = Array(needle)
    for i in 0...(h.count - n.count) where Array(h[i..<i + n.count]) == n { return i }
    return nil
}
private func contains(_ hay: Data, _ needle: Data) -> Bool { offset(of: needle, in: hay) != nil }

extension Scanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("bluetooth state:", stateName(central.state))
        if central.state == .poweredOn {
            // Allow duplicates when hunting a specific phone: its EID advert is
            // intermittent and rotates, so one dedup'd pass can miss it.
            let dup = !targetSeeds.isEmpty
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: dup])
            print("scanning…")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]

        // Phone Hub / Better Together background beacon rides on 0xFE50. Flag it
        // outright (even if the EID doesn't match our period math) so we never
        // miss the phone just because of clock skew or a seed-window edge.
        for (uuid, value) in serviceData where uuid.uuidString.uppercased().hasPrefix("FE50") {
            print(">>> ⬤ FE50 Phone-Hub beacon  data=\(value.hex)  rssi=\(RSSI)")
        }

        // EID match against the target phone's beacon seeds. Search EVERY advert
        // blob (service data + manufacturer data) for any of the nearest 2-byte
        // EIDs at ANY offset — the beacon may frame the EID behind a header
        // (e.g. Eddystone) rather than expose it as a bare 2-byte prefix.
        if !targetSeeds.isEmpty, !flagged.contains(peripheral.identifier) {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let eids = Eid.nearestEids(targetSeeds, nowMs: now).map { $0.eid }
            var blobs: [(String, Data)] = serviceData.map { ($0.key.uuidString, $0.value) }
            if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
                blobs.append(("mfg", mfg))
            }
            for (label, blob) in blobs {
                for eid in eids where contains(blob, eid) {
                    flagged.insert(peripheral.identifier)
                    let off = offset(of: eid, in: blob) ?? -1
                    print(">>> ★ \(targetLabel) MATCH  eid=\(eid.hex)  at=\(label)+\(off)  full=\(blob.hex)  rssi=\(RSSI)")
                }
            }
        }

        guard seen.insert(peripheral.identifier).inserted else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "—"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString }.joined(separator: ",") ?? ""
        let sd = serviceData.map { "\($0.key.uuidString)=\($0.value.hex)" }.joined(separator: " ")
        print("• \(name)  rssi=\(RSSI)  services=[\(services)]  serviceData=[\(sd)]")
    }
}
