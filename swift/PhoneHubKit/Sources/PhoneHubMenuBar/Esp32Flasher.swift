import Foundation
import IOBluetooth

/// Onboarding helper: detect a connected ESP32 board and flash the Chromebook
/// trigger-beacon sketch onto it with `arduino-cli`. The beacon makes the phone
/// show "Set up this Chromebook" (the one signal the Mac can't emit itself).
@MainActor
final class Esp32Flasher: ObservableObject {
    struct Board: Identifiable, Hashable {
        var id: String { port }
        let port: String
        let fqbn: String
        let name: String
    }

    @Published var boards: [Board] = []
    @Published var log = ""
    @Published var busy = false
    @Published var done = false

    private let arduinoCli = "/opt/homebrew/bin/arduino-cli"
    private let repoRoot = "/Users/harsh/Developer/phone-hub-macos"
    private var sketchDir: String { "\(repoRoot)/firmware/chromebook_beacon" }

    /// This Mac's Bluetooth MAC — the beacon points the phone at it.
    var macBtAddress: String {
        IOBluetoothHostController.default()?.addressAsString()?.replacingOccurrences(of: "-", with: ":").uppercased()
            ?? "AA:BB:CC:DD:EE:FF"
    }

    func detectBoards() {
        busy = true; log = "Scanning for boards…\n"
        Task.detached { [arduinoCli] in
            let out = Self.run(arduinoCli, ["board", "list", "--format", "json"]).out
            let boards = Self.parseBoards(out)
            await MainActor.run {
                self.boards = boards
                self.log += boards.isEmpty
                    ? "No ESP32 board found. Plug one in with a USB-C data cable.\n"
                    : boards.map { "Found \($0.name) on \($0.port) [\($0.fqbn)]\n" }.joined()
                self.busy = false
            }
        }
    }

    func flash(_ board: Board, appConfig: AppConfig) {
        busy = true; done = false
        let mac = macBtAddress
        log += "\n→ Flashing \(board.name) on \(board.port)\n→ Mac BT MAC: \(mac)\n"
        let dir = sketchDir, cli = arduinoCli, root = repoRoot
        Task.detached {
            // 1) Generate nc_advert.h for this Mac's BT MAC.
            let gen = Self.run("/usr/bin/python3", ["\(dir)/gen_nc_advert.py", mac])
            if !gen.out.isEmpty {
                try? gen.out.write(toFile: "\(dir)/nc_advert.h", atomically: true, encoding: .utf8)
            }
            await self.append("Generated nc_advert.h (\(gen.out.count) bytes)\n")
            // 2) Compile.
            await self.append("Compiling…\n")
            let c = Self.run(cli, ["compile", "--fqbn", board.fqbn, dir], cwd: root)
            await self.append(c.out + c.err)
            if c.code != 0 { await self.finish(ok: false); return }
            // 3) Upload.
            await self.append("Uploading… (hold BOOT + tap RESET if it stalls)\n")
            let u = Self.run(cli, ["upload", "--fqbn", board.fqbn, "-p", board.port, dir], cwd: root)
            await self.append(u.out + u.err)
            await self.finish(ok: u.code == 0)
        }
    }

    private func append(_ s: String) { log += s }
    private func finish(ok: Bool) {
        busy = false; done = ok
        log += ok ? "\n✅ Flashed. Bring the phone within ~30cm — it should show \"Set up this Chromebook\".\n"
                  : "\n❌ Flash failed — see the log above.\n"
    }

    // MARK: arduino-cli board list parsing

    nonisolated private static func parseBoards(_ json: String) -> [Board] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        // arduino-cli emits either a top-level array or {"detected_ports":[…]}.
        let ports: [[String: Any]]
        if let arr = obj as? [[String: Any]] { ports = arr }
        else if let d = obj as? [String: Any], let p = d["detected_ports"] as? [[String: Any]] { ports = p }
        else { return [] }
        var out: [Board] = []
        for entry in ports {
            guard let portInfo = entry["port"] as? [String: Any],
                  let address = portInfo["address"] as? String,
                  portInfo["protocol"] as? String == "serial" else { continue }
            if address.contains("Bluetooth-Incoming") || address.contains("debug-console") { continue }
            let matching = (entry["matching_boards"] as? [[String: Any]]) ?? []
            let fqbn = (matching.first?["fqbn"] as? String) ?? "esp32:esp32:XIAO_ESP32C6"
            let name = (matching.first?["name"] as? String) ?? "ESP32 (serial)"
            out.append(Board(port: address, fqbn: fqbn, name: name))
        }
        return out
    }

    // MARK: process runner

    nonisolated private static func run(_ path: String, _ args: [String], cwd: String? = nil) -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return ("", "launch failed: \(error)", -1) }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: od, encoding: .utf8) ?? "", String(data: ed, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
