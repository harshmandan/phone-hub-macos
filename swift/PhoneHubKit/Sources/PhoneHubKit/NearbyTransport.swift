import Foundation
import Network

/// The Nearby Connections Wi-Fi LAN medium: a TCP socket carrying length-prefixed
/// (4-byte big-endian) OfflineFrames, advertised over Bonjour as
/// `_FC9F5ED42C8A._tcp.` — the same medium NearDrop uses on macOS.
///
/// This file is the socket + framing foundation. The Bonjour advertising with
/// the endpoint_info and the full connection state machine (ConnectionRequest ↔
/// UKEY2 ↔ ConnectionResponse ↔ payloads) layer on top and need the phone.
/// Transport abstraction: a byte-stream medium carrying 4-byte big-endian
/// length-prefixed Nearby Connections frames. Wi-Fi LAN (`FrameConnection`) and
/// Bluetooth Classic (`RfcommFrameChannel`) both conform, so `NearbyConnection`
/// runs the same state machine over either.
public protocol FrameChannel: AnyObject {
    func start()
    func cancel()
    func sendFrame(_ frame: Data, completion: (() -> Void)?)
    func receiveFrame(_ callback: @escaping (Data?) -> Void)
}

public extension FrameChannel {
    /// Fire-and-forget send (restores the default the concrete types had before
    /// the protocol made `completion` required).
    func sendFrame(_ frame: Data) { sendFrame(frame, completion: nil) }
}

public final class FrameConnection: FrameChannel {
    public static let nearbyServiceType = "_FC9F5ED42C8A._tcp."

    let connection: NWConnection
    private let queue = DispatchQueue(label: "phonehub.nearby")

    public init(_ connection: NWConnection) { self.connection = connection }
    public func start() { connection.start(queue: queue) }
    public func cancel() { connection.cancel() }

    /// Send one frame, 4-byte big-endian length-prefixed.
    public func sendFrame(_ frame: Data, completion: (() -> Void)? = nil) {
        var len = UInt32(frame.count).bigEndian
        let prefixed = withUnsafeBytes(of: &len) { Data($0) } + frame
        connection.send(content: prefixed, completion: .contentProcessed { _ in completion?() })
    }

    /// Receive one length-prefixed frame.
    public func receiveFrame(_ callback: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, _ in
            guard let d = data, d.count == 4 else { callback(nil); return }
            let n = Int(UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3]))
            guard n > 0 else { callback(Data()); return }
            self.connection.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, _ in
                callback(body)
            }
        }
    }
}

public enum NearbyTransport {
    /// Loopback: listener echoes a frame; a client sends one and checks the echo.
    /// Proves the socket + length-prefix framing end to end (no phone needed).
    public static func loopbackTest(timeout: TimeInterval = 5) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var result = false

        let listener = try? NWListener(using: NWParameters(tls: .none))
        guard let listener else { return false }
        listener.newConnectionHandler = { conn in
            let server = FrameConnection(conn)
            server.start()
            server.receiveFrame { frame in
                if let frame { server.sendFrame(frame) }  // echo
            }
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())

        guard ready.wait(timeout: .now() + timeout) == .success,
              let port = listener.port else { return false }

        let payload = NearbyFrames.payloadBytes(id: 1, body: Data("hello nearby".utf8))
        let client = FrameConnection(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        client.start()
        client.receiveFrame { echoed in
            result = (echoed == payload)
            done.signal()
        }
        client.sendFrame(payload)

        _ = done.wait(timeout: .now() + timeout)
        client.cancel()
        listener.cancel()
        return result
    }
}
