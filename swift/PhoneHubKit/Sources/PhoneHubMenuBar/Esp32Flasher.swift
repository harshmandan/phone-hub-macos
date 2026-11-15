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
        let port = board.port, detectedFqbn = board.fqbn
        Task.detached {
            // 0) Resolve the FQBN. arduino-cli auto-detects many boards as the
            // generic esp32:esp32:esp32_family, whose MCU is unset ({build.mcu}),
            // so the build fails. When that happens, ask esptool what chip this
            // actually is and use the concrete board FQBN (e.g. esp32:esp32:esp32c6).
            var fqbn = detectedFqbn
            if fqbn.isEmpty || fqbn.contains("esp32_family") {
                if let (chip, resolved) = Self.resolveChip(port: port) {
                    await self.append("Detected chip \(chip) → \(resolved)\n")
                    fqbn = resolved
                } else {
                    await self.append("⚠︎ Could not auto-detect the chip; trying \(fqbn). If the build fails, pick the board manually.\n")
                }
            }
            // 1) Generate nc_advert.h. The script WRITES the header file itself and
            // prints debug to stdout — so just run it; do NOT capture stdout into
            // the header (that was corrupting it).
            let gen = Self.run("/usr/bin/python3", ["\(dir)/gen_nc_advert.py", mac])
            if gen.code != 0 {
                await self.append("Header generation failed:\n\(gen.out)\(gen.err)\n")
                await self.finish(ok: false); return
            }
            await self.append("Generated nc_advert.h for Mac BT \(mac)\n")
            // 2) Compile.
            await self.append("Compiling (\(fqbn))…\n")
            let c = Self.run(cli, ["compile", "--fqbn", fqbn, dir], cwd: root)
            await self.append(c.out + c.err)
            if c.code != 0 { await self.finish(ok: false); return }
            // 3) Upload.
            await self.append("Uploading… (hold BOOT + tap RESET if it stalls)\n")
            let u = Self.run(cli, ["upload", "--fqbn", fqbn, "-p", port, dir], cwd: root)
            await self.append(u.out + u.err)
            await self.finish(ok: u.code == 0)
        }
    }

    // MARK: chip resolution (so onboarding supports any ESP32 board)

    /// Ask the esp32 core's esptool what chip is on `port` and map it to a concrete
    /// board FQBN, e.g. ("ESP32-C6", "esp32:esp32:esp32c6"). Needed because
    /// arduino-cli reports the generic esp32_family for many boards.
    nonisolated static func resolveChip(port: String) -> (chip: String, fqbn: String)? {
        guard let esptool = esptoolPath() else { return nil }
        let r = run(esptool, ["--port", port, "--no-stub", "chip_id"])
        let text = r.out + "\n" + r.err
        guard let re = try? NSRegularExpression(
                pattern: "(?:Chip is|Detecting chip type\\.\\.\\.)\\s+(ESP32[A-Z0-9-]*)"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let g = Range(m.range(at: 1), in: text) else { return nil }
        let chip = String(text[g])                               // "ESP32-C6"
        let suffix = chip.replacingOccurrences(of: "ESP32", with: "")
            .replacingOccurrences(of: "-", with: "").lowercased() // "c6" (or "" for plain ESP32)
        return (chip, "esp32:esp32:esp32\(suffix)")
    }

    /// The esptool bundled with the installed esp32 Arduino core (newest version).
    nonisolated static func esptoolPath() -> String? {
        let base = "\(NSHomeDirectory())/Library/Arduino15/packages/esp32/tools/esptool_py"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for v in versions.sorted().reversed() {
            let p = "\(base)/\(v)/esptool"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
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
