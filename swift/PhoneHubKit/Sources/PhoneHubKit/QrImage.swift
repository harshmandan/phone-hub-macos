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
}
