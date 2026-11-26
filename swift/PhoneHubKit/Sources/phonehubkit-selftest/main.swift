import Foundation
import PhoneHubKit

let args = CommandLine.arguments
do {
    if args.count == 4 && args[1] == "unwrap" {
        print(try SelfTest.unwrapHex(keyHex: args[2], blobHex: args[3]))
    } else if args.count == 4 && args[1] == "enroll" {
        print(try await Enrollment.enroll(email: args[2], masterToken: args[3]))
    } else if args.count >= 2 && args[1] == "advertise" {
        let secs = args.count >= 3 ? (Double(args[2]) ?? 60) : 60
        Advertiser().run(seconds: secs)
    } else if args.count >= 2 && args[1] == "qr" {
        let b = QuickStart.newBootstrap()
        let url = QuickStart.qrURL(b)
        let path = args.count >= 3 ? args[2] : "/tmp/quickstart-qr.png"
        print(url)
        print(QrImage.writePNG(url, to: path) ? "QR written: \(path)" : "QR render failed")
    } else if args.count >= 2 && args[1] == "qsserve" {
        let b = QuickStart.newBootstrap()
        let url = QuickStart.qrURL(b)
        _ = QrImage.writePNG(url, to: "/tmp/quickstart-qr.png")
        print("QR: \(url)\n     (also /tmp/quickstart-qr.png)")
        if let term = QrImage.terminalQR(url) { print(term) }
        let secs = args.count >= 3 ? (Double(args[2]) ?? 180) : 180
        NearbyAdvertiser.quickStart(name: Host.current().localizedName ?? "Mac", advertisingId: b.advertisingId, sharedSecret: b.sharedSecret).run(seconds: secs)
    } else if args.count >= 2 && args[1] == "btserve" {
        // Nearby Connections over Bluetooth Classic (RFCOMM) — the medium Quick
        // Start actually bootstraps on. Prints this Mac's BT MAC for the injected
        // D2DDevice.bluetoothMacAddr.
        let secs = args.count >= 3 ? (Double(args[2]) ?? 180) : 180
        RfcommNearbyServer(name: Host.current().localizedName ?? "Mac").run(seconds: secs)
    } else if args.count >= 2 && args[1] == "serve" {
        let secs = args.count >= 3 ? (Double(args[2]) ?? 120) : 120
        NearbyAdvertiser(name: Host.current().localizedName ?? "Mac").run(seconds: secs)
    } else if args.count >= 2 && args[1] == "nettest" {
        print(NearbyTransport.loopbackTest() ? "loopback frame transport OK" : "loopback FAILED")
    } else if args.count >= 2 && args[1] == "scan" {
        let secs = args.count >= 3 ? (Double(args[2]) ?? 15) : 15
        let idPath = args.count >= 4 ? args[3] : "../../probe/phone_identity.json"
        var seeds: [Eid.BeaconSeed] = []
        var label = ""
        if let data = FileManager.default.contents(atPath: idPath),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = j["beaconSeeds"] as? [[String: Any]] {
            label = (j["name"] as? String) ?? "phone"
            for s in arr {
                if let hex = s["dataHex"] as? String,
                   let start = (s["startMs"] as? NSNumber)?.int64Value,
                   let end = (s["endMs"] as? NSNumber)?.int64Value {
                    seeds.append(Eid.BeaconSeed(data: Data(hex: hex), startTimeMs: start, endTimeMs: end))
                }
            }
        }
        Scanner(targetSeeds: seeds, targetLabel: label).run(seconds: secs)
    } else if args.count == 4 && args[1] == "diag" {
        print(try await Enrollment.diag(email: args[2], masterToken: args[3]))
    } else if args.count == 4 && args[1] == "sync" {
        print(try await DeviceSync.enrollAndSync(email: args[2], masterToken: args[3]))
    } else if args.count == 5 && args[1] == "cam" {
        print(Enrollment.metadataB64(instanceId: args[2], gcmToken: args[3], longDeviceId: args[4]))
    } else {
        try SelfTest.run()
    }
} catch {
    print("FAILED: \(error)")
    exit(1)
}
