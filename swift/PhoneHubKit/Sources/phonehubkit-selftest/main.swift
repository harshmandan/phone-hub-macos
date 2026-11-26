import Foundation
import PhoneHubKit
import CryptoKit

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
    } else if args.count >= 2 && args[1] == "bleweave" {
        // bleweave [seconds=120] [identity.json] — BLE central: scan the phone's
        // FE50 EID, connect to the b3b7e28e weave GATT, run uWeave.
        let secs = args.count >= 3 ? (Double(args[2]) ?? 120) : 120
        let idPath = args.count >= 4 ? args[3] : "../../probe/phone_identity.json"
        let id: PhoneIdentity
        do { id = try PhoneIdentity.load(idPath) } catch { print(error); exit(1) }
        if id.seeds.isEmpty { print("no phone beacon seeds at \(idPath)"); exit(1) }
        let radio: BleRadio
        do {
            radio = try BleRadio(remoteSeeds: id.seeds, ourLongTermPrivatePem: id.ourPrivatePem,
                                 phoneLongTermPublicGeneric: id.phonePublicGeneric)
        } catch { print("BleRadio init failed: \(error)"); exit(1) }
        radio.onMessage = { print("  [ble] app payload \($0.count)B: \($0.prefix(80).hex)") }
        // Arming for Phone Hub: don't turn on the phone's hotspot (it drops Wi-Fi adb).
        if ProcessInfo.processInfo.environment["PHONEHUB_ARM_ONLY"] != nil { radio.autoConnectTether = false }
        radio.run(seconds: secs)
    } else if args.count >= 3 && args[1] == "phonehub" {
        // phonehub <phone-mac> [seconds=90] [identity.json] [action]
        //   action: ring | dismiss | reply:<text>  (acted on the first snapshot)
        // Holds a BLE weave channel open (which arms the phone's Nearby "secure_
        // channel" listener), then opens the Phone Hub Nearby Connections channel:
        // NC UKEY2 (client) → secure_channel D2D auth → phone_hub status+notifications.
        let secs = args.count >= 4 ? (Double(args[3]) ?? 90) : 90
        let idPath = args.count >= 5 ? args[4] : "../../probe/phone_identity.json"
        let action = args.count >= 6 ? args[5] : ""
        let id: PhoneIdentity
        do { id = try PhoneIdentity.load(idPath) } catch { print(error); exit(1) }
        let client: PhoneHubClient
        do {
            client = try PhoneHubClient(ourLongTermPrivatePem: id.ourPrivatePem,
                                        phoneLongTermPublicGeneric: id.phonePublicGeneric)
        } catch { print("PhoneHubClient init failed: \(error)"); exit(1) }

        // Act on the first status snapshot if an action was requested.
        var acted = false
        client.onSnapshot = { snap in
            // "photos"/"download" are handled via client flags, not snapshot actions.
            guard !acted, !action.isEmpty, action != "photos", action != "download" else { return }
            acted = true
            if action == "ring" {
                print("  [phonehub] → ringing the phone"); client.sendPhoneHub(PhoneHub.ringDevice(on: true), label: "RingDeviceRequest")
            } else if action == "camerasetup" {
                print("  [phonehub] → requesting camera-roll setup (grant on the phone)"); client.sendPhoneHub(PhoneHub.featureSetup(cameraRoll: true), label: "FeatureSetupRequest")
            } else if action == "dismiss", let n = snap.notifications.first {
                print("  [phonehub] → dismissing notification id=\(n.id)"); client.sendPhoneHub(PhoneHub.dismissNotification(id: n.id), label: "DismissNotification")
            } else if action.hasPrefix("reply:"), let n = snap.notifications.first(where: { $0.canReply }) {
                let text = String(action.dropFirst("reply:".count))
                print("  [phonehub] → replying \"\(text)\" to id=\(n.id) [\(n.app)]"); client.sendPhoneHub(PhoneHub.inlineReply(id: n.id, text: text), label: "InlineReply")
            } else { print("  [phonehub] no target for action '\(action)'") }
        }
        if action == "photos" { client.fetchPhotos = true }
        if action == "download" { client.fetchPhotos = true; client.downloadPhotos = true }
        // json: machine-readable mode for the menu-bar app (overrides the handlers
        // above with EVENT-line output + a stdin command loop).
        if action == "json" { JsonDriver.attach(client, photoDir: PhoneHubClient.defaultPhotoDir) }
        // The phone only arms its Nearby "secure_channel" listener while a Better
        // Together BLE weave channel is live, so run `bleweave` concurrently first
        // (scripts/phonehub.sh does this). RFCOMM channel is resolved via SDP.
        client.run(mac: args[2], channelID: 10, seconds: secs)
    } else if args.count >= 3 && args[1] == "sdp" {
        // sdp <phone-mac> [uuid-substring]  — browse the phone's BT services.
        let want = args.count >= 4 ? args[3] : "a384bd4f"  // "secure_channel" Nearby UUID
        SdpProbe().run(mac: args[2], wantUuid: want)
    } else if args.count >= 2 && args[1] == "scan" {
        let secs = args.count >= 3 ? (Double(args[2]) ?? 15) : 15
        let idPath = args.count >= 4 ? args[3] : "../../probe/phone_identity.json"
        let (seeds, label) = PhoneIdentity.loadSeeds(idPath)
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
