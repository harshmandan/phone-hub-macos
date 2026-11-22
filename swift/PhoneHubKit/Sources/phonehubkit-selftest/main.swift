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
    } else if args.count >= 2 && args[1] == "scan" {
        let secs = args.count >= 3 ? (Double(args[2]) ?? 15) : 15
        Scanner().run(seconds: secs)
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
