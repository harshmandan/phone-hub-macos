import Foundation
import Combine

/// Drives the live Phone Hub connection by running the proven CLI as two
/// subprocesses — `bleweave` to arm the phone's Nearby listener, then `phonehub …
/// json` for the actual channel — and turning its EVENT lines into @Published
/// state. (Two processes because CoreBluetooth and IOBluetooth RFCOMM can't share
/// one run loop; see the project notes.) Commands go back over the phonehub
/// process's stdin.
@MainActor
final class PhoneHubEngine: ObservableObject {
    @Published var status: ConnectionStatus = .disconnected
    @Published var phone = PhoneState()
    @Published var notifications: [UINotification] = []
    @Published var photos: [UIPhoto] = []
    @Published private(set) var lastLog = ""

    var config: AppConfig

    private var arm: Process?
    private var nc: Process?
    private var ncStdin: FileHandle?
    private var armBuf = Data()
    private var ncBuf = Data()
    private var ncRetries = 0
    private var armed = false

    init(config: AppConfig) {
        self.config = config
        if config.autoConnect {
            DispatchQueue.main.async { [weak self] in self?.connect() }
        }
    }

    // MARK: lifecycle

    func connect() {
        guard status == .disconnected, !config.phoneBtMac.isEmpty, !config.identityPath.isEmpty else { return }
        notifications = []; photos = []
        armed = false; ncRetries = 0
        status = .arming
        startArm()
    }

    func disconnect() {
        nc?.terminate(); arm?.terminate()
        nc = nil; arm = nil; ncStdin = nil
        status = .disconnected
    }

    // MARK: commands

    func ring() { sendCommand("ring") }
    func reply(to id: Int64, text: String) { sendCommand("reply \(id) \(text)") }
    func dismiss(_ id: Int64) { sendCommand("dismiss \(id)"); notifications.removeAll { $0.id == id } }
    func refreshPhotos() { sendCommand("photos") }

    private func sendCommand(_ cmd: String) {
        guard status == .connected, let h = ncStdin else { return }
        try? h.write(contentsOf: Data((cmd + "\n").utf8))
    }

    // MARK: subprocesses

    private func binary() -> String {
        // Next to this executable (bundled app), else the dev build dir.
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        if let p = exe?.appendingPathComponent("phonehubkit-selftest").path,
           FileManager.default.isExecutableFile(atPath: p) { return p }
        return exe?.appendingPathComponent("phonehubkit-selftest").path
            ?? ".build/debug/phonehubkit-selftest"
    }

    private func launch(_ args: [String], onLine: @escaping (String) -> Void) -> (Process, FileHandle)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary())
        p.arguments = args
        let out = Pipe(); let inp = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            Task { @MainActor in self?.consume(d, onLine: onLine) }
        }
        do { try p.run() } catch { status = .error("launch failed: \(error.localizedDescription)"); return nil }
        return (p, inp.fileHandleForWriting)
    }

    private func consume(_ data: Data, onLine: @escaping (String) -> Void) {
        // Route into the right buffer by identity is overkill; each caller closes
        // over its own line handler, so just split this chunk on newlines.
        var acc = Data()
        for b in data {
            if b == 0x0a {
                if let s = String(data: acc, encoding: .utf8) { onLine(s) }
                acc.removeAll(keepingCapacity: true)
            } else { acc.append(b) }
        }
        if !acc.isEmpty, let s = String(data: acc, encoding: .utf8) { onLine(s) }
    }

    private func startArm() {
        guard let (p, _) = launch(["bleweave", "600", config.identityPath], onLine: { [weak self] line in
            self?.onArmLine(line)
        }) else { return }
        arm = p
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.onArmExit() } }
    }

    private func onArmLine(_ line: String) {
        lastLog = line
        if !armed, line.contains("secure channel established") {
            armed = true
            // Give the phone a few seconds to bring up its Nearby listener.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.startNC() }
        }
    }

    private func onArmExit() {
        if status != .disconnected { status = .error("BLE arm process exited") }
    }

    private func startNC() {
        guard status == .arming || status == .connecting, arm != nil else { return }
        status = .connecting
        guard let (p, stdin) = launch(["phonehub", config.phoneBtMac, "120", config.identityPath, "json"],
                                      onLine: { [weak self] line in self?.onNcLine(line) }) else { return }
        nc = p; ncStdin = stdin
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.onNcExit() } }
    }

    private func onNcExit() {
        ncStdin = nil; nc = nil
        guard status != .disconnected else { return }
        // The RFCOMM accept is timing-sensitive; retry a couple of times.
        if status == .connecting, ncRetries < 3 {
            ncRetries += 1
            lastLog = "retrying Nearby connection (\(ncRetries)/3)…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startNC() }
        } else if status == .connected {
            status = .error("connection dropped")
        } else {
            status = .error("could not reach Phone Hub")
        }
    }

    private func onNcLine(_ line: String) {
        lastLog = line
        if line.contains("secure_channel established over Nearby") { status = .connected }
        guard line.hasPrefix("EVENT ") else { return }
        let json = String(line.dropFirst("EVENT ".count))
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "status":
            status = .connected
            phone.battery = obj["battery"] as? Int
            phone.charging = (obj["charging"] as? Bool) ?? false
            phone.signalBars = obj["signalBars"] as? Int
            phone.carrier = (obj["carrier"] as? String) ?? ""
            phone.androidVersion = obj["android"] as? Int
            phone.cameraRollGranted = (obj["cameraRoll"] as? Bool) ?? false
            phone.phoneName = config.phoneName
            phone.lastUpdated = Date()
        case "notification":
            guard let idStr = obj["id"] as? String, let id = Int64(idStr) else { return }
            let n = UINotification(id: id, app: (obj["app"] as? String) ?? "",
                                   title: (obj["title"] as? String) ?? "",
                                   text: (obj["text"] as? String) ?? "",
                                   canReply: (obj["canReply"] as? Bool) ?? false)
            if let i = notifications.firstIndex(where: { $0.id == id }) { notifications[i] = n }
            else { notifications.insert(n, at: 0) }
        case "removed":
            if let idStr = obj["id"] as? String, let id = Int64(idStr) { notifications.removeAll { $0.id == id } }
        case "photo":
            let p = UIPhoto(key: (obj["key"] as? String) ?? "",
                            fileName: (obj["fileName"] as? String) ?? "",
                            mime: (obj["mime"] as? String) ?? "",
                            sizeKB: Int((obj["sizeKB"] as? String) ?? "0") ?? 0,
                            thumbnailPath: (obj["thumb"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            if !photos.contains(where: { $0.key == p.key }) { photos.append(p) }
        default: break
        }
    }
}
