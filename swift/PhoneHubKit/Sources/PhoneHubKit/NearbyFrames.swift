import Foundation

/// Nearby Connections OfflineFrames — the connection protocol on top of the
/// UKEY2-secured channel. Ports the key frames from offline_wire_formats.proto.
///
/// Frames travel over the medium socket length-prefixed (4-byte big-endian).
/// After UKEY2, the channel is AES-256-CBC+HMAC (our SecureContext). App data
/// (the Quick Start messages) rides inside PayloadTransferFrame BYTES payloads.
public enum NearbyFrames {
    // V1Frame.FrameType
    static let frameConnectionRequest: UInt64 = 1
    static let frameConnectionResponse: UInt64 = 2
    static let framePayloadTransfer: UInt64 = 3
    static let frameKeepAlive: UInt64 = 5
    // PayloadTransferFrame.PacketType / PayloadType / ResponseStatus
    static let packetData: UInt64 = 1
    static let payloadTypeBytes: UInt64 = 1
    static let responseAccept: UInt64 = 1

    private static func offlineFrame(_ v1: Data) -> Data {
        Pb.varint(1, 1 /* V1 */) + Pb.message(2, v1)
    }

    // MARK: builders

    public static func connectionRequest(endpointId: String, endpointInfo: Data, nonce: Int32) -> Data {
        var req = Data()
        req += Pb.bytes(1, Data(endpointId.utf8))     // endpoint_id
        req += Pb.varint(4, UInt64(bitPattern: Int64(nonce)))  // nonce
        req += Pb.varint(5, 5 /* WIFI_LAN */)         // mediums
        req += Pb.bytes(6, endpointInfo)              // endpoint_info
        let v1 = Pb.varint(1, frameConnectionRequest) + Pb.message(2, req)
        return offlineFrame(v1)
    }

    public static func connectionResponse(accept: Bool) -> Data {
        let resp = Pb.varint(3, accept ? responseAccept : UInt64(2))   // response: ACCEPT/REJECT
        let v1 = Pb.varint(1, frameConnectionResponse) + Pb.message(3, resp)
        return offlineFrame(v1)
    }

    public static func keepAlive(ack: Bool, seq: UInt32) -> Data {
        var ka = Data()
        ka += Pb.varint(1, ack ? 1 : 0)
        ka += Pb.varint(2, UInt64(seq))
        let v1 = Pb.varint(1, frameKeepAlive) + Pb.message(6, ka)
        return offlineFrame(v1)
    }

    /// A single-chunk BYTES payload carrying `body`.
    public static func payloadBytes(id: Int64, body: Data, lastChunk: Bool = true,
                                    totalSize: Int? = nil, offset: Int = 0) -> Data {
        var header = Data()
        header += Pb.varint(1, UInt64(bitPattern: id))   // id
        header += Pb.varint(2, payloadTypeBytes)         // type = BYTES
        header += Pb.varint(3, UInt64(totalSize ?? body.count))  // total_size
        var chunk = Data()
        chunk += Pb.varint(1, lastChunk ? 1 : 0)         // flags (1 = last)
        chunk += Pb.varint(2, UInt64(offset))            // offset
        if !body.isEmpty { chunk += Pb.bytes(3, body) }  // body
        var pt = Data()
        pt += Pb.varint(1, packetData)                   // packet_type = DATA
        pt += Pb.message(2, header)                      // payload_header
        pt += Pb.message(3, chunk)                       // payload_chunk
        let v1 = Pb.varint(1, framePayloadTransfer) + Pb.message(4, pt)
        return offlineFrame(v1)
    }

    // MARK: parse

    public static func frameType(_ offlineFrame: Data) -> UInt64? {
        let f = Pb.readFields(offlineFrame)
        guard let v1 = f.bytes(2) else { return nil }
        return Pb.readFields(v1).varint(1)
    }

    /// Extract a BYTES payload body (and whether it is the last chunk).
    public static func payloadBody(_ offlineFrame: Data) -> (id: Int64, body: Data, last: Bool)? {
        let f = Pb.readFields(offlineFrame)
        guard let v1 = f.bytes(2) else { return nil }
        let frame = Pb.readFields(v1)
        guard frame.varint(1) == framePayloadTransfer, let ptBytes = frame.bytes(4) else { return nil }
        let pt = Pb.readFields(ptBytes)
        let id = Int64(bitPattern: Pb.readFields(pt.bytes(2) ?? Data()).varint(1) ?? 0)
        guard let chunkBytes = pt.bytes(3) else { return nil }
        let chunk = Pb.readFields(chunkBytes)
        let body = chunk.bytes(3) ?? Data()
        let last = (chunk.varint(1) ?? 0) & 1 == 1
        return (id, body, last)
    }

    // MARK: length-prefix framing (over the socket)

    public static func lengthPrefixed(_ frame: Data) -> Data {
        var be = UInt32(frame.count).bigEndian
        return withUnsafeBytes(of: &be) { Data($0) } + frame
    }
}
