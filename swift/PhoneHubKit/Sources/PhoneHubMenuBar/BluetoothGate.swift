import Foundation
import CoreBluetooth

/// Watches the app's Bluetooth permission + power from the MAIN process. The
/// bleweave subprocess does the real BLE, but it shares this app bundle's
/// permission, so checking here is accurate. Instantiating a central triggers the
/// macOS "allow Bluetooth" prompt the first time — we do that at launch so it
/// appears while the user is present, not mid-connect from a background process.
@MainActor final class BluetoothGate: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var authorization = CBCentralManager.authorization
    @Published private(set) var poweredOn = false
    private var central: CBCentralManager?
    /// Fires when Bluetooth becomes usable (authorized + powered on).
    var onReady: (() -> Void)?

    /// Create the central (prompts for permission if it hasn't been asked).
    func start() { if central == nil { central = CBCentralManager(delegate: self, queue: .main) } }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var isAuthorized: Bool { authorization == .allowedAlways }
    var isUnknown: Bool { authorization == .notDetermined }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let on = c.state == .poweredOn
        Task { @MainActor in
            self.authorization = CBCentralManager.authorization
            self.poweredOn = on
            if self.isAuthorized && on { self.onReady?() }
        }
    }
}
