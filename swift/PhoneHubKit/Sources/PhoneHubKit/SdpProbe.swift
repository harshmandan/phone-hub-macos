#if canImport(IOBluetooth)
import Foundation
import IOBluetooth

/// SDP-browse a paired phone to see what Bluetooth-Classic services it exposes,
/// and find the RFCOMM channel for a given Nearby service UUID. The Phone Hub
/// connection is an out-of-band Nearby Connections link over RFCOMM: before
/// building the connector we need to confirm the phone hosts the Nearby
/// "secure_channel" service and learn its channel.
public final class SdpProbe: NSObject {
    private var done = false

    public func run(mac: String, wantUuid: String?) {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let device = IOBluetoothDevice(addressString: mac) else {
            print("bad address \(mac)"); return
        }
        print("SDP query \(mac) (\(device.name ?? "?")) …")
        // performSDPQuery delivers sdpQueryComplete: to the target.
        device.performSDPQuery(self)
        let deadline = Date().addingTimeInterval(20)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        listServices(device, wantUuid: wantUuid)
    }

    private func listServices(_ device: IOBluetoothDevice, wantUuid: String?) {
        guard let services = device.services as? [IOBluetoothSDPServiceRecord], !services.isEmpty else {
            print("no services (SDP query failed or empty)"); return
        }
        print("— \(services.count) service record(s) —")
        for rec in services {
            let name = rec.getServiceName() ?? "(unnamed)"
            var ch: BluetoothRFCOMMChannelID = 0
            let hasRfcomm = rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess
            var uuids: [String] = []
            if let attrs = rec.attributes as? [NSNumber: IOBluetoothSDPDataElement] {
                for (_, el) in attrs { collectUuids(el, into: &uuids) }
            }
            let rf = hasRfcomm ? "rfcomm=\(ch)" : "no-rfcomm"
            print("• \(name)  \(rf)")
            let uniq = Set(uuids)
            if !uniq.isEmpty { print("    uuids: \(uniq.sorted().joined(separator: ", "))") }
            if let want = wantUuid?.lowercased(), uniq.contains(where: { $0.lowercased().contains(want) }) {
                print("    >>> ★ MATCH for \(want)  (connect RFCOMM channel \(hasRfcomm ? String(ch) : "?"))")
            }
        }
    }

    private func collectUuids(_ el: IOBluetoothSDPDataElement, into out: inout [String]) {
        if let uuid = el.getUUIDValue() {
            out.append(uuid.description.replacingOccurrences(of: " ", with: ""))
        }
        if let arr = el.getArrayValue() as? [IOBluetoothSDPDataElement] {
            for e in arr { collectUuids(e, into: &out) }
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        print("sdpQueryComplete status=\(status)")
        done = true
    }
}
#endif
