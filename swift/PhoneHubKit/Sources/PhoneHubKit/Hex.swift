import Foundation

extension Data {
    init(hex: String) {
        var out = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self = out
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// base64url with padding (matches Python base64.urlsafe_b64encode).
    var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

enum Form {
    /// application/x-www-form-urlencoded body.
    static func encode(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
