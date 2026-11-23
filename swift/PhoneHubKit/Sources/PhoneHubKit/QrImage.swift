import Foundation
import CoreImage
import CoreGraphics
import ImageIO

/// Render a string as a QR-code PNG (CoreImage). Used to produce a scannable
/// Quick Start QR for testing against a real phone.
public enum QrImage {
    public static func writePNG(_ string: String, to path: String) -> Bool {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return false }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        else { return false }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return false }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Render the QR as half-block text for the terminal, with explicit black/white
    /// colors (scannable on any terminal theme) and a white quiet-zone border.
    public static func terminalQR(_ string: String, border: Int = 2) -> String? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let img = filter.outputImage else { return nil }
        let ext = img.extent
        let w = Int(ext.width), h = Int(ext.height)
        guard w > 0, h > 0 else { return nil }

        var px = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = CIContext().createCGImage(img, from: ext) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // true = dark module. CoreGraphics is bottom-left origin, so flip y.
        func dark(_ x: Int, _ y: Int) -> Bool {
            let bx = x - border, by = y - border
            if bx < 0 || by < 0 || bx >= w || by >= h { return false }   // white border
            return px[(h - 1 - by) * w + bx] < 128
        }
        let W = w + border * 2, H = h + border * 2
        let reset = "\u{1b}[0m"
        func fg(_ d: Bool) -> String { d ? "\u{1b}[38;5;0m" : "\u{1b}[38;5;15m" }
        func bg(_ d: Bool) -> String { d ? "\u{1b}[48;5;0m" : "\u{1b}[48;5;15m" }

        var out = reset + "\n"
        var y = 0
        while y < H {
            var line = ""
            for x in 0..<W {
                let top = dark(x, y)
                let bot = (y + 1 < H) ? dark(x, y + 1) : false   // pad with white
                line += fg(top) + bg(bot) + "\u{2580}"            // ▀ upper half block
            }
            out += line + reset + "\n"
            y += 2
        }
        return out
    }
}
