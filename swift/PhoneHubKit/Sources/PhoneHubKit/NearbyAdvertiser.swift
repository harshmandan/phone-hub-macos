import Foundation
import Network

/// Advertise the Mac as a Nearby Connections endpoint over Bonjour + TCP, the
/// NearDrop way. Lets us check empirically that macOS Nearby advertising reaches
/// the phone.
///
/// Defaults to the **Quick Share** service id (`_FC9F5ED42C8A._tcp.`, hash bytes
/// FC 9F 5E), so the phone's Quick Share should list the Mac. Quick Start uses a
/// DIFFERENT service id → a different service type + hash bytes; that swap is the
/// remaining Quick-Start-specific step (TODO: extract from Chromium's
/// target_device_connection_broker).
public final class NearbyAdvertiser: NSObject {
    // Device types (EndpointInfo): unknown=0, phone=1, tablet=2, laptop=3.
    static let deviceTypeLaptop = 3
    public static let quickShareServiceType = "_FC9F5ED42C8A._tcp."
    public static let quickShareServiceIdHash: [UInt8] = [0xFC, 0x9F, 0x5E]

    private var listener: NWListener!
    private var service: NetService?
    private let name: String
    private let serviceType: String
    private let serviceIdHash: [UInt8]

    public init(name: String, serviceType: String = quickShareServiceType,
                serviceIdHash: [UInt8] = quickShareServiceIdHash) {
        self.name = name
        self.serviceType = serviceType
        self.serviceIdHash = serviceIdHash
        super.init()
    }

    private func randomEndpointId() -> [UInt8] {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        return (0..<4).map { _ in alphabet.randomElement()! }
    }

    private func endpointInfo() -> Data {
        var info: [UInt8] = [UInt8(NearbyAdvertiser.deviceTypeLaptop << 1)]  // byte 0
        info += (0..<16).map { _ in UInt8.random(in: 0...255) }             // 16 random
        let nameBytes = Array(name.utf8).prefix(255)
        info.append(UInt8(nameBytes.count))
        info += nameBytes
        return Data(info)
    }

    public func run(seconds: Double) {
        setvbuf(stdout, nil, _IONBF, 0)
        listener = try! NWListener(using: NWParameters(tls: .none))
        listener.newConnectionHandler = { conn in
            print("!! phone connected:", conn.endpoint)
            let nearby = NearbyConnection(FrameConnection(conn))
            nearby.start()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = self.listener.port {
                self.publishMDNS(port: Int32(port.rawValue))
                print("listening on \(port); advertising \"\(self.name)\" as \(self.serviceType)")
            }
        }
        listener.start(queue: .global())
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        service?.stop()
        listener.cancel()
        print("advertiser done")
    }

    private func publishMDNS(port: Int32) {
        let nameBytes: [UInt8] = [0x23] + randomEndpointId() + serviceIdHash + [0, 0]
        let serviceName = Data(nameBytes).base64url.replacingOccurrences(of: "=", with: "")
        let s = NetService(domain: "", type: serviceType, name: serviceName, port: port)
        let n = endpointInfo().base64url.replacingOccurrences(of: "=", with: "")
        s.setTXTRecord(NetService.data(fromTXTRecord: ["n": Data(n.utf8)]))
        s.publish()
        service = s
    }
}
