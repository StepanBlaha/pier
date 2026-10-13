import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Square module grid, no quiet zone. Row-major, top-left origin; true = dark.
public struct QRMatrix: Equatable, Sendable {
    public let size: Int
    public let modules: [Bool]

    public init(size: Int, modules: [Bool]) {
        precondition(modules.count == size * size)
        self.size = size; self.modules = modules
    }

    /// Out-of-range coordinates (the quiet zone) are light.
    public func isDark(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < size && y < size && modules[y * size + x]
    }
}

public enum QR {
    public enum Failure: Error, LocalizedError {
        case loopbackOnly(hint: String?)
        case noLANAddress
        public var errorDescription: String? {
            switch self {
            case .loopbackOnly(let hint):
                "service is bound to localhost only; restart it with --host 0.0.0.0" + (hint.map { " (e.g. `\($0)`)" } ?? "")
            case .noLANAddress:
                "no LAN address detected for this service"
            }
        }
    }

    /// The URL a phone on the same network can reach, or why there isn't one.
    public static func lanURL(for service: Service) throws -> String {
        guard service.bindScope != .loopback else { throw Failure.loopbackOnly(hint: hint(for: service.framework)) }
        guard let url = service.lanURL else { throw Failure.noLANAddress }
        return url
    }

    /// Framework-specific command to bind on all interfaces.
    public static func hint(for framework: Framework?) -> String? {
        switch framework?.id {
        case "next": "next dev -H 0.0.0.0"
        case "vite", "sveltekit": "vite --host"
        case "astro": "astro dev --host"
        case "nuxt": "nuxt dev --host"
        case "remix": "remix vite:dev --host"
        case "rails": "rails s -b 0.0.0.0"
        case "flask": "flask run --host 0.0.0.0"
        case "django": "python manage.py runserver 0.0.0.0:8000"
        case "fastapi": "uvicorn main:app --host 0.0.0.0"
        default: nil
        }
    }

    /// QR matrix via CoreImage (error correction M).
    public static func matrix(for text: String) -> QRMatrix? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, w == h, let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }

        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // CoreImage pads the symbol with a light border; crop to the bounding box of dark modules.
        let dark = pixels.map { $0 < 128 }
        let coords = dark.indices.filter { dark[$0] }
        guard let lo = coords.map({ $0 % w }).min(), let hi = coords.map({ $0 % w }).max(),
              let top = coords.map({ $0 / w }).min() else { return nil }
        let size = hi - lo + 1
        var modules: [Bool] = []
        modules.reserveCapacity(size * size)
        for y in top ..< top + size { for x in lo ... hi { modules.append(dark[y * w + x]) } }
        return QRMatrix(size: size, modules: modules)
    }
}
