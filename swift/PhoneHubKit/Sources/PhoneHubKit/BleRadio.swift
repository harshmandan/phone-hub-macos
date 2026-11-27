import Foundation
import CoreBluetooth
import CryptoKit

/// The CoreBluetooth radio: the Mac acts as BLE central, finds the phone by its
/// rotating EID, connects, runs uWeave, then the D2D SecureChannel auth, then
/// decodes feature messages. VERIFIED LIVE against a Pixel 9 (the full chain —
/// FE50 scan → b3b7e28e GATT → uWeave → D2D auth → feature messages — works).
///
/// Sources:
///   GATT service + weave characteristic UUIDs (ble_constants.h /
///   ble_weave_client_connection.cc). NOTE: this GMS build exposes the
///   PRE-migration characteristic UUIDs (…0101/…0102), not the current ones:
///     https://chromium.googlesource.com/chromium/src/+/a753229/components/proximity_auth/ble/bluetooth_low_energy_weave_client_connection.cc
///     https://chromium.googlesource.com/chromium/src/+/main/chromeos/ash/services/secure_channel/ble_constants.h
///   The scan→connect→authenticate→feature flow mirrors secure_channel's
///   BleConnectionManager + DeviceToDeviceAuthenticator (see DeviceToDevice.swift).
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
    private var receiver = Weave.PacketReceiver()
    private var generator = Weave.PacketGenerator()

    /// The remote phone's beacon seeds (from its DeviceSync metadata), used to
    /// recognise its rotating advertisement.
    private let remoteSeeds: [Eid.BeaconSeed]

    // D2D SecureChannel auth over the weave channel.
    private let handshake: D2D.Handshake
    private var helloSent = false
    private var context: D2D.SecureContext?
    private var writeQueue: [Data] = []
    private var writing = false
    // Phone Hub: the phone registers its message processor shortly AFTER the
    // channel authenticates, so a single CrosState can race it ("no
    // messageProcessor registered"). Retry on a timer until a phone_hub reply
    // arrives — this is what ChromeOS's CrosStateSender does.
    private var crosStateTimer: Timer?
    private var gotPhoneHub = false
    private var gotTether = false
    private var sentConnect = false

    /// Called with each fully-reassembled secure-channel message.
    public var onMessage: ((Data) -> Void)?

    public init(remoteSeeds: [Eid.BeaconSeed],
                ourLongTermPrivatePem: String,
                phoneLongTermPublicGeneric: Data) throws {
        self.remoteSeeds = remoteSeeds
        let priv = try P256.KeyAgreement.PrivateKey(pemRepresentation: ourLongTermPrivatePem)
        let pub = try SecureMessage.parseGenericPublicKey(phoneLongTermPublicGeneric)
        self.handshake = try D2D.Handshake(ourLongTermPrivate: priv, phoneLongTermPublic: pub)
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

    /// Queue one raw weave packet and pump the queue. Writes are serialized:
    /// the phone's TX is [write] (with response), so we wait for each
    /// didWriteValueFor before the next (a .withoutResponse write to a
    /// [write]-only characteristic is silently dropped).
    private func enqueue(_ packet: Data) {
        writeQueue.append(packet)
        pump()
    }

    private func pump() {
        guard !writing, let p = peripheral, let tx, !writeQueue.isEmpty else { return }
        let type: CBCharacteristicWriteType =
            tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let packet = writeQueue.removeFirst()
        writing = true
        p.writeValue(packet, for: tx, type: type)
        if type == .withoutResponse { writing = false; pump() }
    }

    /// Send a uWeave control packet (connection request/response/close).
    private func sendControl(_ packet: Data) { enqueue(packet) }

    /// WireMessage-frame a SecureChannel message and send it as uWeave data
    /// packets (the phone's BleSecureChannel requires the WireMessage wrapper).
    private func sendMessage(_ message: Data, feature: String, label: String) {
        let wire = WireMessage.serialize(payload: message, feature: feature)
        let packets = generator.encodeDataMessage(wire)
        log("→ \(label) (\(message.count)B → wire \(wire.count)B → \(packets.count) packets)")
        packets.forEach(enqueue)
    }

    private func requestFeatures() {
        guard let ctx = context else { return }
        sendMessage(ctx.encode(PhoneHub.crosState()), feature: PhoneHub.feature,
                    label: "CrosState (phone_hub, attestation-walled)")
        sendMessage(ctx.encode(Tether.availabilityRequest_()), feature: Tether.feature,
                    label: "TetherAvailabilityRequest (magic_tether)")
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("write error: \(error.localizedDescription)") }
        writing = false
        pump()
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
        sendControl(generator.connectionRequest())
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.rxCharacteristicUUID, let value = characteristic.value else { return }
        log("← weave rx \(value.count)B: \(value.prefix(48).hex)")
        do {
            switch try receiver.receive(value) {
            case .control(let cmd):
                if cmd == Weave.connectionResponse, !helloSent {
                    helloSent = true
                    log("uWeave connected — sending D2D [Initiator Hello]")
                    sendMessage(handshake.initiatorHello(), feature: WireMessage.authFeature, label: "[Initiator Hello]")
                } else if cmd == Weave.connectionClose {
                    log("uWeave connectionClose from phone")
                }
            case .incomplete:
                break  // more packets of a data message to come
            case .message(let message):
                handleChannelMessage(message)
            }
        } catch {
            log("weave receive error: \(error)")
        }
    }

    private func handleChannelMessage(_ wire: Data) {
        // Incoming messages are WireMessage-framed; unwrap to the SecureMessage
        // and the feature it belongs to.
        guard let (message, feature) = WireMessage.parse(wire) else {
            log("← non-WireMessage frame (\(wire.count)B): \(wire.prefix(32).hex)")
            return
        }
        if context == nil {
            // First message after the hello = the phone's [Responder Auth].
            log("← [Responder Auth] (\(message.count)B) — deriving session, sending [Initiator Auth]")
            do {
                let auth = try handshake.initiatorAuth(forResponderAuth: message)
                context = handshake.context
                sendMessage(auth, feature: WireMessage.authFeature, label: "[Initiator Auth]")
                log("🔑 D2D secure channel established")
                // Request features and retry until one answers. Phone Hub is
                // attestation-walled; Instant Tethering (magic_tether) is not.
                requestFeatures()
                crosStateTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] t in
                    guard let self else { t.invalidate(); return }
                    if self.gotTether { t.invalidate(); return }
                    self.requestFeatures()
                }
            } catch {
                log("D2D auth failed: \(error)")
            }
            return
        }
        // Secure channel is up: decrypt the feature message.
        do {
            let payload = try context!.decode(message)
            if feature == Tether.feature {
                gotTether = true
                crosStateTimer?.invalidate()
                let t = Tether.parse(payload)
                log("📡 \(t.summary)")
                // When the phone says tethering is available, ask it to start the
                // hotspot and hand back Wi-Fi credentials (user-approved action —
                // this turns the phone's hotspot on).
                if t.type == Tether.availabilityResponse, t.available, !sentConnect, let ctx = context {
                    sentConnect = true
                    log("→ requesting hotspot (ConnectTetheringRequest) …")
                    sendMessage(ctx.encode(Tether.connectRequest_()), feature: Tether.feature,
                                label: "ConnectTetheringRequest")
                }
                if t.type == Tether.connectResponse, let ssid = t.ssid, let pw = t.password {
                    log("🛜  HOTSPOT READY  →  SSID: \(ssid)   PASSWORD: \(pw)")
                }
            } else if feature == PhoneHub.feature {
                gotPhoneHub = true
                log("📱 \(PhoneHub.describe(payload))")
            } else {
                log("🔓 [\(feature)] \(payload.count)B: \(payload.prefix(64).hex)")
            }
            onMessage?(payload)
        } catch {
            log("decode failed [\(feature)] (\(message.count)B): \(error)")
        }
    }
}
