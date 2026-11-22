import Foundation

/// Minimal protobuf wire encode/decode — the Swift port of the probe's `pb.py`.
/// Only what the ported crypto needs.
enum PBField {
    case varint(UInt64)
    case bytes(Data)
}

enum Pb {
    static func varintBytes(_ value: UInt64) -> Data {
        var n = value
        var out = Data()
        repeat {
            var b = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { b |= 0x80 }
            out.append(b)
        } while n != 0
        return out
    }

    static func tag(_ field: Int, _ wire: Int) -> Data {
        varintBytes(UInt64(field << 3 | wire))
    }

    static func varint(_ field: Int, _ value: UInt64) -> Data {
        tag(field, 0) + varintBytes(value)
    }

    static func bytes(_ field: Int, _ value: Data) -> Data {
        tag(field, 2) + varintBytes(UInt64(value.count)) + value
    }

    static func message(_ field: Int, _ value: Data) -> Data {
        bytes(field, value)
    }

    /// Decode top-level fields. Varints and length-delimited only (all we use).
    static func readFields(_ input: Data) -> [Int: PBField] {
        let data = Data(input)  // rebase indices to 0
        var out: [Int: PBField] = [:]
        var i = data.startIndex

        func readVarint() -> UInt64 {
            var v: UInt64 = 0
            var s = 0
            while i < data.endIndex {
                let b = data[i]
                i = data.index(after: i)
                v |= UInt64(b & 0x7F) << s
                if b & 0x80 == 0 { break }
                s += 7
            }
            return v
        }

        while i < data.endIndex {
            let key = readVarint()
            let field = Int(key >> 3)
            let wire = Int(key & 7)
            if wire == 0 {
                out[field] = .varint(readVarint())
            } else if wire == 2 {
                let len = Int(readVarint())
                let end = data.index(i, offsetBy: len)
                out[field] = .bytes(Data(data[i..<end]))
                i = end
            } else {
                break
            }
        }
        return out
    }
}

extension Dictionary where Key == Int, Value == PBField {
    func bytes(_ field: Int) -> Data? {
        if case .bytes(let d)? = self[field] { return d }
        return nil
    }
    func varint(_ field: Int) -> UInt64? {
        if case .varint(let v)? = self[field] { return v }
        return nil
    }
}
