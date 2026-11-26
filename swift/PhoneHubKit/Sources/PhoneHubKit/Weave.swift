import Foundation

/// uWeave: chunking messages into BLE-sized packets. Port of `ble/weave.py`.
enum Weave {
    static let dataType = 0
    static let controlType = 1
    static let connectionRequest = 0
    static let connectionResponse = 1
    static let connectionClose = 2
    static let defaultMaxPacketSize = 20
    static let version: UInt16 = 1
    static let selectMaxPacketSize: UInt16 = 0
    static let maxPacketCounter = 8

    static func short(_ v: UInt16) -> Data {
        var be = v.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    final class PacketGenerator {
        let maxPacketSize: Int
        private var nextCounter = 0

        init(maxPacketSize: Int = defaultMaxPacketSize) {
            self.maxPacketSize = maxPacketSize
        }

        private func counterBits() -> Int {
            let c = nextCounter % maxPacketCounter
            nextCounter += 1
            return c << 4
        }

        func connectionRequest() -> Data {
            let header = UInt8((Weave.controlType << 7) | Weave.connectionRequest)
            nextCounter = 1
            return Data([header]) + Weave.short(Weave.version) + Weave.short(Weave.version) + Weave.short(Weave.selectMaxPacketSize)
        }

        func connectionResponse() -> Data {
            let header = UInt8((Weave.controlType << 7) | Weave.connectionResponse)
            nextCounter = 1
            return Data([header]) + Weave.short(Weave.version) + Weave.short(UInt16(maxPacketSize))
        }

        func connectionClose(reason: UInt16 = 0) -> Data {
            let header = UInt8((Weave.controlType << 7) | counterBits() | Weave.connectionClose)
            return Data([header]) + Weave.short(reason)
        }

        func encodeDataMessage(_ message: Data) -> [Data] {
            precondition(!message.isEmpty)
            let payloadSize = maxPacketSize - 1
            let n = (message.count + payloadSize - 1) / payloadSize
            var packets: [Data] = []
            for i in 0..<n {
                let begin = i * payloadSize
                let end = min(begin + payloadSize, message.count)
                var header = (dataType << 7) | counterBits()
                if i == 0 { header |= 1 << 3 }       // first
                if i == n - 1 { header |= 1 << 2 }   // last
                packets.append(Data([UInt8(header)]) + message[begin..<end])
            }
            return packets
        }
    }

    final class PacketReceiver {
        private var nextCounter = 0
        private var started = false
        private var buffer = Data()
        private var receiving = false

        struct SequenceError: Error { let got: Int }
        struct FirstBitError: Error {}

        static func packetType(_ p: Data) -> Int { Int((p[p.startIndex] >> 7) & 1) }
        static func controlCommand(_ p: Data) -> Int { Int(p[p.startIndex] & 0x0F) }
        static func isFirst(_ p: Data) -> Bool { (p[p.startIndex] >> 3) & 1 == 1 }
        static func isLast(_ p: Data) -> Bool { (p[p.startIndex] >> 2) & 1 == 1 }

        enum Result {
            case control(Int)
            case incomplete
            case message(Data)
        }

        func receive(_ p: Data) throws -> Result {
            let count = Int((p[p.startIndex] >> 4) & 7)
            // Sync to the peer's first packet counter — GMS may continue a weave
            // counter from a prior session rather than restart at 0.
            if !started { nextCounter = count; started = true }
            guard count == nextCounter % maxPacketCounter else { throw SequenceError(got: count) }
            nextCounter += 1

            if Self.packetType(p) == controlType {
                return .control(Self.controlCommand(p))
            }
            if Self.isFirst(p) != !receiving { throw FirstBitError() }
            if Self.isFirst(p) {
                buffer = Data()
                receiving = true
            }
            buffer += p[(p.startIndex + 1)...]
            if Self.isLast(p) {
                receiving = false
                return .message(buffer)
            }
            return .incomplete
        }
    }
}
